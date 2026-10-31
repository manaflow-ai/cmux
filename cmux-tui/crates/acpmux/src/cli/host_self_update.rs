//! `acpmux host self-update`: a Linux host brings its own daemon to the
//! newest build of a channel (feat-cmux-next) with no Mac pushing it;
//! `acpmux-update.timer` (`host_auto_update.rs`) runs it every 15 minutes.
//! CI writes the channel file `cmux-tui/channels/<channel>.json` once a
//! tree's daemon tests passed: the tree key, its commit and each acpmux
//! binary's sha256. When the installed `~/.local/bin/acpmux` has another
//! sha256, this host's binary is downloaded from that tree, checked against
//! it, and handed to [`update_peer`] on this machine ([`LocalRemote`]): it
//! installs the binary, restarts `acpmux.service` (agents keep running and
//! the new daemon adopts them, so what the restart interrupted resumes) and
//! rolls back a daemon that does not come back on it. A build rolled back
//! here is not tried again; the next one the channel names is. A failure
//! after the push (the binary is put back) and a refusal before it are
//! retried at the next run. The host's update lock (a lease in `~/.acpmux`,
//! `host_lock.rs`) is held from the channel read to the check or rollback,
//! and every script the update runs checks it is still this update's:
//! `host update`, `host setup` and `host enroll --fix` from another machine
//! take the same lease, so no two updates replace the binary or
//! `acpmux.prev` at once.

use super::super::host_auto_update::NO_AUTO_UPDATE;
use super::super::host_lock::Lease;
use super::super::{Remote, RemoteOut};
use super::{
    CLOUD_VM_MARK, OWN_UNIT, Outcome, PeerUpdate, UpdateOptions, embedded_build, is_own_unit,
    local_target, update_peer,
};
use crate::cli::output::print_json;
use anyhow::{Context, Result, anyhow, bail};
use futures::future::BoxFuture;
use serde::Deserialize;
use serde_json::json;
use std::collections::BTreeMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};

/// Where CI publishes the cmux-tui builds: public, no credentials.
const FILES: &str = "https://files.cmux.com/cmux-tui";

/// A channel file is a few hundred bytes, a binary tens of megabytes.
const CHANNEL_MAX_BYTES: usize = 64 * 1024;
const BINARY_MAX_BYTES: usize = 512 * 1024 * 1024;

/// What a download folder holds once its build was rolled back here.
pub(super) const ROLLED_BACK: &str = "rolled-back";

/// A channel file as CI writes it.
#[derive(Debug, Deserialize)]
pub(super) struct Channel {
    /// The tree whose folder (`cmux-tui/tree/<key>/`) holds the binaries.
    pub(super) key: String,
    /// The channel commit the tree was tested for. The binaries may report an
    /// older commit of the same tree, so a host compares files, not commits.
    pub(super) commit: String,
    /// Each binary's sha256, by its published name (`cmux-tui-acpmux-<target>`).
    pub(super) binaries: BTreeMap<String, String>,
}

impl Channel {
    /// A channel file's contents, its key and commit full lowercase hashes.
    pub(super) fn parse(body: &[u8]) -> Result<Channel> {
        let channel: Channel =
            serde_json::from_slice(body).context("the channel file is not a channel")?;
        if !lower_hex(&channel.key, 40) {
            bail!("the channel file names no tree key");
        }
        if !lower_hex(&channel.commit, 40) {
            bail!("the channel file names no commit");
        }
        Ok(channel)
    }

    /// The sha256 of the acpmux build for `target`.
    pub(super) fn sha256_for(&self, target: &str) -> Result<&str> {
        let name = format!("cmux-tui-acpmux-{target}");
        let sha = self
            .binaries
            .get(&name)
            .ok_or_else(|| anyhow!("the channel has no acpmux build for {target} ({name})"))?;
        if !lower_hex(sha, 64) {
            bail!("the channel's sha256 for {name} is not a sha256");
        }
        Ok(sha)
    }

    fn binary_url(&self, target: &str) -> String {
        format!("{FILES}/tree/{}/cmux-tui-acpmux-{target}", self.key)
    }
}

/// `len` lowercase hex digits.
fn lower_hex(text: &str, len: usize) -> bool {
    text.len() == len && text.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// The URL of a channel's file; a channel is lowercase letters, digits and `-`.
pub(super) fn channel_url(channel: &str) -> Result<String> {
    let plain = !channel.is_empty()
        && channel.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-');
    if !plain {
        bail!("refusing the channel {channel:?}: lowercase letters, digits and - only");
    }
    Ok(format!("{FILES}/channels/{channel}.json"))
}

/// Reads a URL. The command uses [`HttpsFetch`]; tests pass fakes, so they
/// need no network.
pub(super) trait Fetch: Send + Sync {
    /// The body of `url`, at most `max` bytes.
    fn get<'a>(&'a self, url: &'a str, max: usize) -> BoxFuture<'a, Result<Vec<u8>, String>>;
}

/// An HTTPS GET with no redirects, a timeout and a body cap, through the
/// crate's reqwest and ring rustls provider (as `catalog/fetch.rs`).
struct HttpsFetch;

impl HttpsFetch {
    async fn body(url: &str, max: usize) -> Result<Vec<u8>, String> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let client = reqwest::Client::builder()
            .https_only(true)
            .redirect(reqwest::redirect::Policy::none())
            .timeout(std::time::Duration::from_secs(600))
            .user_agent(concat!("acpmux/", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(|e| e.to_string())?;
        let mut response = client.get(url).send().await.map_err(|e| e.to_string())?;
        let status = response.status().as_u16();
        if status != 200 {
            return Err(format!("the server answered {status}"));
        }
        let over = || format!("the body is above the {max} byte limit");
        if response.content_length().is_some_and(|n| n > max as u64) {
            return Err(over());
        }
        let mut body = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(|e| e.to_string())? {
            if body.len() + chunk.len() > max {
                return Err(over());
            }
            body.extend_from_slice(&chunk);
        }
        Ok(body)
    }
}

impl Fetch for HttpsFetch {
    fn get<'a>(&'a self, url: &'a str, max: usize) -> BoxFuture<'a, Result<Vec<u8>, String>> {
        Box::pin(Self::body(url, max))
    }
}

/// What a self-update reads and writes on the host; tests point it at a
/// fake home.
pub(super) struct Paths {
    /// The default acpmux home `~/.acpmux`, whatever `ACPMUX_HOME` says (the
    /// binary is the user's, not a daemon home's): `update.lock`, which
    /// `host update` over ssh takes too, and the downloads in
    /// `update/<sha256>/`.
    pub(super) home: PathBuf,
    /// The binary `acpmux.service` runs: `~/.local/bin/acpmux`.
    pub(super) installed: PathBuf,
    /// [`NO_AUTO_UPDATE`] in the home, where `host setup` leaves it.
    pub(super) off: PathBuf,
    /// [`CLOUD_VM_MARK`].
    pub(super) cloud_vm: PathBuf,
    /// `~/.config/systemd/user/acpmux.service` ([`OWN_UNIT`]).
    pub(super) unit: PathBuf,
    /// This host's release target, as `acpmux-<target>` names it.
    pub(super) target: &'static str,
}

impl Paths {
    fn here() -> Result<Paths> {
        let target =
            local_target().ok_or_else(|| anyhow!("no acpmux build runs on this platform"))?;
        let user = dirs::home_dir().ok_or_else(|| anyhow!("this user has no home folder"))?;
        let home = crate::config::default_home();
        Ok(Paths {
            installed: user.join(".local/bin/acpmux"),
            off: home.join(NO_AUTO_UPDATE),
            home,
            cloud_vm: PathBuf::from(CLOUD_VM_MARK),
            unit: user.join(OWN_UNIT),
            target,
        })
    }
}

/// What [`prepare`] found, before anything on the host changed.
pub(super) enum Prepared {
    /// Automatic updates are off ([`Paths::off`]).
    Off,
    /// Another update holds the host's update lock.
    Locked,
    /// The channel's binary (of this commit) was rolled back here before;
    /// it is not tried again.
    RolledBackBefore(String),
    Ready(Plan),
}

/// The channel's build for this host and what to do with it.
pub(super) struct Plan {
    pub(super) commit: String,
    pub(super) sha256: String,
    pub(super) step: Step,
    /// `update/<sha256>/`, holding the checked `acpmux-<target>`.
    dir: PathBuf,
    /// The host's update lease, held until the plan is dropped.
    lease: Lease,
}

pub(super) enum Step {
    /// The installed binary is the channel's; the build it carries. The
    /// daemon may still run another (an update stopped between the install
    /// and the restart), so [`apply`] still checks it.
    Current(Option<String>),
    /// Install the checked binary in this folder (`acpmux-<target>`).
    Install(PathBuf),
}

/// Take the update lock, read the channel and, when the installed binary
/// differs from the channel's, download this host's binary into
/// `update/<sha256>/` (kept for the next run; other builds' folders go) and
/// check its sha256. Errors (a Cloud VM without acpmux's own `acpmux.service`, a channel without this target, a
/// download that does not match) change nothing on the host.
pub(super) async fn prepare(paths: &Paths, fetch: &dyn Fetch, channel: &str) -> Result<Prepared> {
    if paths.off.exists() {
        return Ok(Prepared::Off);
    }
    if paths.cloud_vm.exists() && !own_unit(&paths.unit) {
        bail!("this host is a cmux Cloud VM: `cmux link machine update --to-bundled` updates it");
    }
    let url = channel_url(channel)?;
    let Some(lease) = Lease::take(&paths.home)? else {
        return Ok(Prepared::Locked);
    };
    let body = fetch
        .get(&url, CHANNEL_MAX_BYTES)
        .await
        .map_err(|e| anyhow!("reading the {channel} channel ({url}): {e}"))?;
    let feed = Channel::parse(&body).with_context(|| format!("the {channel} channel ({url})"))?;
    let sha = feed.sha256_for(paths.target)?.to_owned();
    let downloads = paths.home.join("update");
    prune(&downloads, &sha);
    let installed = std::fs::read(&paths.installed).ok();
    let dir = downloads.join(&sha);
    let step = match installed {
        Some(bytes) if crate::sha256::sha256_hex(&bytes) == sha => {
            keep(&dir, paths.target, &bytes)?;
            Step::Current(embedded_build(&bytes))
        }
        _ if downloads.join(&sha).join(ROLLED_BACK).is_file() => {
            return Ok(Prepared::RolledBackBefore(feed.commit));
        }
        _ => Step::Install(download(fetch, &feed, paths.target, &sha, &downloads).await?),
    };
    Ok(Prepared::Ready(Plan { commit: feed.commit, sha256: sha, step, dir, lease }))
}

/// Whether `unit` is acpmux's own `acpmux.service` ([`is_own_unit`]): a regular
/// file, not a link. On a cmux Cloud VM only that daemon is this host's to
/// update; the update's probe then checks the daemon runs under it
/// (`cloud_vm_check`, `host_update.rs`).
fn own_unit(unit: &Path) -> bool {
    std::fs::symlink_metadata(unit).is_ok_and(|m| m.file_type().is_file())
        && std::fs::read(unit).is_ok_and(|text| is_own_unit(&text))
}

/// Remove the download folders (`<sha256>/`) of builds other than `keep`,
/// except a rolled-back build's [`ROLLED_BACK`] marker: only its binary goes,
/// so the channel moving on and back never installs that build again.
fn prune(downloads: &Path, keep: &str) {
    let Ok(entries) = std::fs::read_dir(downloads) else { return };
    for entry in entries.flatten() {
        let name = entry.file_name();
        if !name.to_str().is_some_and(|n| n != keep && lower_hex(n, 64)) {
            continue;
        }
        let dir = entry.path();
        if !dir.join(ROLLED_BACK).is_file() {
            let _ = std::fs::remove_dir_all(&dir);
            continue;
        }
        for file in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
            if file.file_name() != ROLLED_BACK {
                let _ = std::fs::remove_file(file.path());
            }
        }
    }
}

/// `downloads/<sha>/acpmux-<target>`, downloaded unless a run before left it
/// there; a body whose sha256 is not `sha` is never written. The folder.
async fn download(
    fetch: &dyn Fetch,
    feed: &Channel,
    target: &str,
    sha: &str,
    downloads: &Path,
) -> Result<PathBuf> {
    let dir = downloads.join(sha);
    let path = dir.join(format!("acpmux-{target}"));
    if std::fs::read(&path).is_ok_and(|bytes| crate::sha256::sha256_hex(&bytes) == sha) {
        return Ok(dir);
    }
    let url = feed.binary_url(target);
    let bytes =
        fetch.get(&url, BINARY_MAX_BYTES).await.map_err(|e| anyhow!("downloading {url}: {e}"))?;
    let got = crate::sha256::sha256_hex(&bytes);
    if got != sha {
        bail!("{url} has sha256 {got}, not the channel's {sha}, so it is not installed");
    }
    keep(&dir, target, &bytes)?;
    Ok(dir)
}

/// `dir/acpmux-<target>` holds `bytes` (already checked), written beside and
/// renamed; a copy with these bytes already there is kept.
fn keep(dir: &Path, target: &str, bytes: &[u8]) -> Result<()> {
    let path = dir.join(format!("acpmux-{target}"));
    if std::fs::read(&path).is_ok_and(|have| have == bytes) {
        return Ok(());
    }
    std::fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
    let part = dir.join(format!(".acpmux-{target}.part"));
    std::fs::write(&part, bytes).with_context(|| format!("writing {}", part.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&part, std::fs::Permissions::from_mode(0o755))?;
    }
    std::fs::rename(&part, &path).with_context(|| format!("writing {}", path.display()))?;
    Ok(())
}

/// Carry out `plan` on `remote` (this machine), every script fenced for its
/// lease: the row `host update` prints for a peer. Either step goes through
/// [`update_peer`], which leaves a daemon already on the channel's build
/// alone and restarts one that is not, so an update stopped between the
/// install and the restart is finished by the next run (review of #24232). A
/// build whose daemon was rolled back is marked, so the next run leaves it
/// alone; when the mark cannot be written, the row says so.
pub(super) fn apply(remote: &dyn Remote, plan: &Plan, target: &'static str) -> PeerUpdate {
    let (dir, installed) = match &plan.step {
        Step::Current(build) => (&plan.dir, build.as_deref()),
        Step::Install(dir) => (dir, None),
    };
    let opts = UpdateOptions {
        binary_dir: Some(dir.clone()),
        if_idle: false,
        keep_newer: false,
        caller: None,
    };
    let mut up = update_peer(&plan.lease.fence(remote), &opts);
    up.target.get_or_insert(target);
    if up.outcome == Outcome::Current && up.build.is_none() {
        up.build = installed.map(str::to_owned);
    }
    if up.outcome == Outcome::RolledBack {
        let mark = dir.join(ROLLED_BACK);
        if let Err(e) = std::fs::write(&mark, up.error.as_deref().unwrap_or("")) {
            let why = up.error.take().unwrap_or_default();
            up.error = Some(format!(
                "{why}; marking the build rolled back failed ({}: {e}), so the next run tries it again",
                mark.display()
            ));
        }
    }
    up
}

/// This machine as a [`Remote`]: a script runs under `sh -c` in the home
/// folder, with `stdin` fed to it, and a push is a copy (`~/` is the home).
pub(super) struct LocalRemote;

impl Remote for LocalRemote {
    fn host(&self) -> &str {
        "localhost"
    }

    fn exec(&self, script: &str, stdin: Option<&[u8]>) -> Result<RemoteOut> {
        let mut command = Command::new("sh");
        command.args(["-c", script]);
        if let Some(home) = dirs::home_dir() {
            command.current_dir(home);
        }
        let mut child = command
            .stdin(if stdin.is_some() { Stdio::piped() } else { Stdio::null() })
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .context("sh")?;
        if let (Some(bytes), Some(mut pipe)) = (stdin, child.stdin.take()) {
            pipe.write_all(bytes).context("sh: stdin")?;
        }
        let out = child.wait_with_output().context("sh")?;
        Ok(RemoteOut {
            ok: out.status.success(),
            stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
        })
    }

    fn spawn(&self, script: &str) -> Result<Child> {
        let mut command = Command::new("sh");
        command.args(["-c", script]);
        if let Some(home) = dirs::home_dir() {
            command.current_dir(home);
        }
        command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .context("sh")
    }

    fn push(&self, local: &Path, remote: &str) -> Result<()> {
        let dest = match remote.strip_prefix("~/") {
            Some(rest) => {
                dirs::home_dir().ok_or_else(|| anyhow!("this user has no home folder"))?.join(rest)
            }
            None => PathBuf::from(remote),
        };
        std::fs::copy(local, &dest)
            .with_context(|| format!("copying {} to {}", local.display(), dest.display()))?;
        Ok(())
    }
}

/// `acpmux host self-update [--channel C]` (see the module doc), Linux only.
/// Prints the row `host update` prints for a peer, named by this host's name;
/// `--json` prints `{"channel", "commit", "sha256", "updated": [ROW]}`. With
/// automatic updates off, another update of this host running, or the channel's
/// build rolled back here before, nothing happens: `{"channel", "skipped":
/// "off" | "locked" | "rolledBack", "message", "updated": []}`, exit 0.
/// Exits 1 when the row failed. The channel decides: a build pushed by hand
/// with `host update` is replaced by the channel's at the next run, unless
/// automatic updates are off.
pub(crate) async fn self_update(channel: &str, json_out: bool) -> Result<()> {
    if std::env::consts::OS != "linux" {
        bail!(
            "host self-update keeps a Linux host's own daemon updated; update another machine with `acpmux host update NAME`"
        );
    }
    let paths = Paths::here()?;
    let plan = match prepare(&paths, &HttpsFetch, channel).await? {
        Prepared::Off => {
            let why = format!(
                "automatic updates are off on this host (remove {} to turn them on)",
                paths.off.display()
            );
            return skipped(channel, "off", &why, json_out);
        }
        Prepared::Locked => {
            let why = "another update of this host is running (a host update, or this timer)";
            return skipped(channel, "locked", why, json_out);
        }
        Prepared::RolledBackBefore(commit) => {
            let why = format!(
                "the {channel} build of commit {commit} was rolled back on this host before; waiting for a newer one"
            );
            return skipped(channel, "rolledBack", &why, json_out);
        }
        Prepared::Ready(plan) => plan,
    };
    let up = apply(&LocalRemote, &plan, paths.target);
    let name = crate::hand::pair::hostname();
    if json_out {
        print_json(&json!({
            "channel": channel,
            "commit": plan.commit,
            "sha256": plan.sha256,
            "updated": [up.to_json(&name, LocalRemote.host())],
        }));
    } else if up.outcome.failed() {
        eprintln!("{name} (local): {}", up.line());
    } else {
        println!("{name} (local): {}", up.line());
    }
    if up.outcome.failed() {
        // crash-allow: the row above is the whole output; exit 1 is the documented failure code, as in `host update`
        std::process::exit(1);
    }
    Ok(())
}

fn skipped(channel: &str, why: &str, message: &str, json_out: bool) -> Result<()> {
    if json_out {
        print_json(&json!({"channel": channel, "skipped": why, "message": message, "updated": []}));
    } else {
        println!("{message}");
    }
    Ok(())
}
