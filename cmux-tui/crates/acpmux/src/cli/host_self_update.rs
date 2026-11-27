//! `acpmux host self-update`: a Linux host brings its own daemon to the
//! newest build of a channel (feat-cmux-next) with no Mac pushing it;
//! `acpmux-update.timer` (`host_auto_update.rs`) runs it every 15 minutes.
//! Two places name a channel's build. Our build controller (cmuxterm-hq's
//! `build-fleet`) runs the channel's daemon tests and builds acpmux itself,
//! and on a pass serves a marker at `{controller}/v1/channels/<channel>`:
//! the commit and each target's sha256, the binary fetched through
//! `{controller}/v1/artifacts/sha256:<hex>/url`. The controller is reached
//! over the tailnet with no token (`CMUX_CI_CONTROLLER`, else the fleet
//! client's `client.json`). GitHub Actions writes the channel file
//! `cmux-tui/channels/<channel>.json` on R2 once a tree's daemon tests
//! passed: the tree key, its commit and each acpmux binary's sha256. The R2
//! channel is always read (cmux-rd follows it); acpmux follows the
//! controller's marker when it is on (mode `on`) and has this host's target,
//! and the R2 channel otherwise: a controller that is down, a marker that is
//! off, in `report` mode or unreadable is a note in the output, never a
//! failed update. The controller's build of a commit has another sha256
//! than R2's build of it, so when R2 decides, an installed build of the
//! same commit (most likely the marker's) is kept. When the installed
//! `~/.local/bin/acpmux` has another sha256 than the chosen build, this
//! host's binary is downloaded, checked against it, and handed to
//! [`update_peer`] on this machine ([`LocalRemote`]): it installs the binary, restarts `acpmux.service` (agents keep running and
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
//! After acpmux's step, the cmux-tui beside it (the one the `chief` harness
//! runs) is brought to the same R2 tree (`host_self_update_tui.rs`).

use super::super::host_auto_update::NO_AUTO_UPDATE;
use super::super::host_lock::Lease;
use super::super::{REMOTE_HOME, Remote, RemoteOut};
use super::{
    CLOUD_VM_MARK, OWN_UNIT, Outcome, PeerUpdate, RESTART_STAMP, RESTART_WINDOW,
    RESTART_WINDOW_ENV, RESTART_WINDOW_FILE, RESTART_WINDOW_SECS, UpdateOptions, build_commit,
    embedded_build, is_own_unit, local_target, update_peer,
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

#[path = "host_self_update_rd.rs"]
pub(super) mod rd;

#[path = "host_self_update_fast_patch.rs"]
pub(crate) mod fast_patch;
use rd::{RdOutcome, RdPaths};

#[path = "host_self_update_tui.rs"]
pub(super) mod tui;

#[path = "host_update_watch.rs"]
pub(super) mod watch;
use tui::{TuiOutcome, TuiSource};

/// Where CI publishes the cmux-tui builds: public, no credentials.
const FILES: &str = "https://files.cmux.com/cmux-tui";

/// A channel file or marker is a few hundred bytes, a binary tens of megabytes.
const CHANNEL_MAX_BYTES: usize = 64 * 1024;
const BINARY_MAX_BYTES: usize = 512 * 1024 * 1024;

/// What a download folder holds once its build was rolled back here.
pub(super) const ROLLED_BACK: &str = "rolled-back";

/// A channel file as CI writes it.
#[derive(Debug, Deserialize)]
pub(crate) struct Channel {
    /// The tree whose folder (`cmux-tui/tree/<key>/`) holds the binaries.
    pub(super) key: String,
    /// The channel commit the tree was tested for. The binaries may report an
    /// older commit of the same tree, so a host compares files, not commits.
    pub(super) commit: String,
    /// Each binary's sha256, by its published name (`cmux-tui-acpmux-<target>`).
    pub(super) binaries: BTreeMap<String, String>,
    /// Builds pulled from the channel (hq RFD "One update system for every place cmux runs"):
    /// each a 40-hex commit or a 64-hex binary sha256. A host running one goes back to the
    /// channel's build at once, as `--allow-downgrade --now` would, and no marker naming one is
    /// installed. Missing in channel files from before the field.
    #[serde(default)]
    pub(super) revoked: Vec<String>,
}

impl Channel {
    /// A channel file's contents, its key and commit full lowercase hashes.
    pub(crate) fn parse(body: &[u8]) -> Result<Channel> {
        let channel: Channel =
            serde_json::from_slice(body).context("the channel file is not a channel")?;
        if !lower_hex(&channel.key, 40) {
            bail!("the channel file names no tree key");
        }
        if !lower_hex(&channel.commit, 40) {
            bail!("the channel file names no commit");
        }
        if let Some(bad) = channel.revoked.iter().find(|r| !lower_hex(r, 40) && !lower_hex(r, 64)) {
            bail!("the channel file revokes {bad:?}, not a commit or a sha256");
        }
        if channel.revoked.contains(&channel.commit)
            || channel.binaries.values().any(|sha| channel.revoked.contains(sha))
        {
            bail!("the channel file names a build it also revokes");
        }
        Ok(channel)
    }

    /// The sha256 of the acpmux build for `target`.
    pub(crate) fn sha256_for(&self, target: &str) -> Result<&str> {
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

    /// Why the build `sha256` (of commit `commit`, when known) is revoked by this channel.
    pub(super) fn revokes(&self, sha256: &str, commit: Option<&str>) -> Option<String> {
        let hit = self.revoked.iter().find(|r| {
            r.as_str() == sha256
                || commit.is_some_and(|c| c.len() >= 7 && r.len() == 40 && r.starts_with(c))
        })?;
        Some(format!("the channel revokes {hit}"))
    }

    /// [`Channel::revokes`] for a binary's bytes.
    pub(super) fn revokes_binary(&self, bytes: &[u8]) -> Option<String> {
        let build = embedded_build(bytes);
        self.revokes(&crate::sha256::sha256_hex(bytes), build.as_deref().and_then(build_commit))
    }

    pub(crate) fn binary_url(&self, target: &str) -> String {
        format!("{FILES}/tree/{}/cmux-tui-acpmux-{target}", self.key)
    }
}

/// `len` lowercase hex digits.
fn lower_hex(text: &str, len: usize) -> bool {
    text.len() == len && text.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// The URL of a channel's file; a channel is lowercase letters, digits and `-`.
pub(crate) fn channel_url(channel: &str) -> Result<String> {
    let plain = !channel.is_empty()
        && channel.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-');
    if !plain {
        bail!("refusing the channel {channel:?}: lowercase letters, digits and - only");
    }
    Ok(format!("{FILES}/channels/{channel}.json"))
}

/// Reads a URL. The command uses [`WebFetch`]; tests pass fakes, so they
/// need no network.
pub(super) trait Fetch: Send + Sync {
    /// The body of `url`, at most `max` bytes.
    fn get<'a>(&'a self, url: &'a str, max: usize) -> BoxFuture<'a, Result<Vec<u8>, String>>;
}

/// A GET with no redirects, a timeout and a body cap, through the crate's
/// reqwest and ring rustls provider (as `catalog/fetch.rs`).
struct WebFetch {
    /// Refuse plain http: the R2 files and the binaries the controller's
    /// presigned URLs point at are HTTPS. The controller itself is plain
    /// http on the tailnet.
    https_only: bool,
    /// The whole request's limit, and the connect's.
    timeout: std::time::Duration,
    connect_timeout: std::time::Duration,
}

/// R2: the channel file and every binary download.
const R2_FETCH: WebFetch = WebFetch {
    https_only: true,
    timeout: std::time::Duration::from_secs(600),
    connect_timeout: std::time::Duration::from_secs(30),
};

/// The build controller's marker and artifact lookup: small answers, so a
/// controller that is down costs the timer seconds, not minutes.
const CONTROLLER_FETCH: WebFetch = WebFetch {
    https_only: false,
    timeout: std::time::Duration::from_secs(10),
    connect_timeout: std::time::Duration::from_secs(5),
};

impl WebFetch {
    async fn body(&self, url: &str, max: usize) -> Result<Vec<u8>, String> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let client = crate::happy_dial::http_client()
            .https_only(self.https_only)
            .redirect(reqwest::redirect::Policy::none())
            .timeout(self.timeout)
            .connect_timeout(self.connect_timeout)
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

impl Fetch for WebFetch {
    fn get<'a>(&'a self, url: &'a str, max: usize) -> BoxFuture<'a, Result<Vec<u8>, String>> {
        Box::pin(self.body(url, max))
    }
}

/// The build controller a self-update asks first: its base URL (no trailing
/// `/`) and how it is read.
pub(super) struct Controller<'a> {
    pub(super) url: String,
    pub(super) fetch: &'a dyn Fetch,
}

impl Controller<'_> {
    /// The base URL: `CMUX_CI_CONTROLLER`, else `controller` in the fleet
    /// client's `~/.local/share/cmux-fleet-client/client.json`. None when
    /// neither names an http(s) URL.
    fn configured() -> Option<String> {
        let from_env = std::env::var("CMUX_CI_CONTROLLER").ok().filter(|v| !v.trim().is_empty());
        let url = from_env.or_else(|| {
            let file = dirs::home_dir()?.join(".local/share/cmux-fleet-client/client.json");
            let text = std::fs::read(file).ok()?;
            let client: serde_json::Value = serde_json::from_slice(&text).ok()?;
            client.get("controller")?.as_str().map(str::to_owned)
        })?;
        let url = url.trim().trim_end_matches('/').to_owned();
        (url.starts_with("http://") || url.starts_with("https://")).then_some(url)
    }

    fn marker_url(&self, channel: &str) -> String {
        format!("{}/v1/channels/{channel}", self.url)
    }

    fn artifact_url(&self, sha: &str) -> String {
        format!("{}/v1/artifacts/sha256:{sha}/url", self.url)
    }

    /// The channel's marker, when it is on and has an acpmux build for
    /// `target`; else why it is not used.
    async fn marker(&self, channel: &str, target: &str) -> Result<Marker, String> {
        let url = self.marker_url(channel);
        let body = self
            .fetch
            .get(&url, CHANNEL_MAX_BYTES)
            .await
            .map_err(|e| format!("reading the controller's marker ({url}): {e}"))?;
        let marker = Marker::parse(&body, channel, target)
            .map_err(|e| format!("the controller's marker ({url}): {e}"))?;
        Ok(marker)
    }

    /// The presigned URL of the binary whose sha256 is `sha`.
    async fn binary_url(&self, sha: &str) -> Result<String, String> {
        let url = self.artifact_url(sha);
        let body = self
            .fetch
            .get(&url, CHANNEL_MAX_BYTES)
            .await
            .map_err(|e| format!("asking the controller for the binary ({url}): {e}"))?;
        let answer: ArtifactUrl = serde_json::from_slice(&body)
            .map_err(|e| format!("the controller's answer ({url}) is not an artifact URL: {e}"))?;
        if answer.sha256 != format!("sha256:{sha}") {
            return Err(format!("the controller ({url}) answered for {}", answer.sha256));
        }
        if !answer.url.starts_with("https://") {
            return Err(format!("the controller ({url}) gave a URL that is not https"));
        }
        Ok(answer.url)
    }
}

/// `{controller}/v1/artifacts/sha256:<hex>/url`'s answer.
#[derive(Deserialize)]
struct ArtifactUrl {
    url: String,
    sha256: String,
}

/// The build controller's channel marker (schema `ci-channel/v1`), the
/// fields a self-update reads.
#[derive(Debug, Deserialize)]
struct MarkerFile {
    schema: String,
    channel: String,
    commit: String,
    /// `on` is installed from; `report` (the controller tests and builds but
    /// GitHub Actions' channel still decides) and anything else is not.
    #[serde(default)]
    mode: String,
    /// sha256s by binary, then by target: `"sha256:<hex>"`.
    #[serde(default)]
    binaries: BTreeMap<String, BTreeMap<String, String>>,
}

/// A marker a self-update installs from.
#[derive(Debug)]
pub(super) struct Marker {
    commit: String,
    sha256: String,
}

impl Marker {
    fn parse(body: &[u8], channel: &str, target: &str) -> Result<Marker, String> {
        let file: MarkerFile =
            serde_json::from_slice(body).map_err(|e| format!("not a marker: {e}"))?;
        if file.schema != "ci-channel/v1" {
            return Err(format!("schema {:?}, not ci-channel/v1", file.schema));
        }
        if file.channel != channel {
            return Err(format!("it is for channel {:?}, not {channel}", file.channel));
        }
        if file.mode != "on" {
            return Err(format!("its mode is {:?}, not \"on\"", file.mode));
        }
        if !lower_hex(&file.commit, 40) {
            return Err("it names no commit".to_owned());
        }
        let sha = file
            .binaries
            .get("acpmux")
            .and_then(|targets| targets.get(target))
            .ok_or_else(|| format!("it has no acpmux build for {target}"))?;
        let sha = sha
            .strip_prefix("sha256:")
            .filter(|hex| lower_hex(hex, 64))
            .ok_or_else(|| format!("its sha256 for {target} is not a sha256"))?;
        Ok(Marker { commit: file.commit, sha256: sha.to_owned() })
    }
}

/// Where the plan's acpmux build comes from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Source {
    Controller,
    R2,
}

impl Source {
    pub(super) fn name(self) -> &'static str {
        match self {
            Source::Controller => "controller",
            Source::R2 => "r2",
        }
    }
}

/// Which build a self-update follows and why the marker was not used.
pub(super) struct Picked {
    pub(super) source: Source,
    /// Why the controller's marker was skipped, when the R2 channel decided.
    pub(super) marker_skipped: Option<String>,
    /// Why the installed build was kept over the R2 channel's: it is built
    /// from the same commit ([`same_commit`]).
    pub(super) kept_installed: Option<String>,
}

impl Picked {
    fn json(&self) -> serde_json::Value {
        json!({
            "source": self.source.name(),
            "markerSkipped": self.marker_skipped,
            "keptInstalled": self.kept_installed,
        })
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
    /// cmux-rd, the screen host's program, kept on the channel's build too
    /// (`host_self_update_rd.rs`); None leaves it alone.
    pub(super) rd: Option<RdPaths>,
    /// The cmux-tui beside the installed acpmux, the one the `chief` harness runs
    /// (`config::discover::add_chief`), kept on the channel's tree after acpmux's step
    /// (`host_self_update_tui.rs`); None leaves it alone.
    pub(super) tui: Option<PathBuf>,
    /// Install the channel's build even when the installed one is built from
    /// a newer commit (`--allow-downgrade`: pulling a bad channel build back).
    /// Off, the host keeps a newer build ([`apply`]).
    pub(super) allow_downgrade: bool,
}

impl Paths {
    fn here(now: bool, allow_downgrade: bool) -> Result<Paths> {
        let target =
            local_target().ok_or_else(|| anyhow!("no acpmux build runs on this platform"))?;
        let user = dirs::home_dir().ok_or_else(|| anyhow!("this user has no home folder"))?;
        let home = crate::config::default_home();
        let installed = user.join(".local/bin/acpmux");
        Ok(Paths {
            tui: Some(installed.with_file_name("cmux-tui")),
            installed,
            off: home.join(NO_AUTO_UPDATE),
            rd: RdPaths::here(&user, &home, target, now),
            allow_downgrade,
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
    /// The chosen binary (of this commit) was rolled back here before; it is
    /// not tried again. What happened to cmux-rd, and where the build came
    /// from.
    RolledBackBefore(String, RdOutcome, Picked),
    Ready(Plan),
}

/// The channel's build for this host and what to do with it.
pub(super) struct Plan {
    pub(super) commit: String,
    pub(super) sha256: String,
    pub(super) step: Step,
    /// What happened to cmux-rd ([`rd::refresh`]), before acpmux's step.
    pub(super) rd: RdOutcome,
    /// The controller's marker or the R2 channel.
    pub(super) picked: Picked,
    /// [`Paths::allow_downgrade`], or the installed build is revoked.
    allow_downgrade: bool,
    /// Why the installed build is revoked by the channel ([`Channel::revoked`]): the update
    /// goes back to the channel's build now, past the restart window.
    pub(super) revoked_installed: Option<String>,
    /// The R2 channel's tree for cmux-tui ([`tui::refresh`] after acpmux's step), or why the
    /// channel could not be read.
    pub(super) tui_source: Result<TuiSource, String>,
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

/// Take the update lock, read the R2 channel (and refresh cmux-rd from it),
/// then pick acpmux's build: the `controller`'s marker when it is on and has
/// this host's target, else the R2 channel's. When the installed binary
/// differs from it, download this host's binary into `update/<sha256>/`
/// (kept for the next run; other builds' folders go) and check its sha256.
/// A controller that cannot be read, or cannot give the binary's URL, falls
/// back to the R2 channel ([`Picked::marker_skipped`] says why). Errors (a
/// Cloud VM without acpmux's own `acpmux.service`, a channel without this
/// target, a download that does not match) change nothing on the host.
pub(super) async fn prepare(
    paths: &Paths,
    fetch: &dyn Fetch,
    controller: Option<&Controller<'_>>,
    channel: &str,
) -> Result<Prepared> {
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
    // The R2 channel is read every run (cmux-rd follows it), but an R2 that
    // cannot be read fails only the R2 path: the controller's marker still
    // updates acpmux, so the update never depends on a service we do not run.
    let feed = match fetch.get(&url, CHANNEL_MAX_BYTES).await {
        Err(e) => Err(format!("reading the {channel} channel ({url}): {e}")),
        Ok(body) => {
            Channel::parse(&body).map_err(|e| format!("the {channel} channel ({url}): {e:#}"))
        }
    };
    let tui_source = match &feed {
        Ok(feed) => Ok(TuiSource::of(feed, paths.target)),
        Err(why) => Err(why.clone()),
    };
    // cmux-rd first: a restart of acpmux below never waits on it, and its
    // outcome never fails acpmux's update.
    let rd = match (&paths.rd, &feed) {
        (None, _) => RdOutcome::NotJoined,
        (Some(_), Err(why)) => RdOutcome::Failed(why.clone()),
        (Some(rd_paths), Ok(feed)) => {
            rd::refresh(rd_paths, fetch, feed, std::time::SystemTime::now()).await
        }
    };
    let downloads = paths.home.join("update");
    let installed = std::fs::read(&paths.installed).ok();
    // A revoked installed build is pulled back to the channel's, newer or not.
    let revoked_installed = match (&feed, installed.as_deref()) {
        (Ok(feed), Some(bytes)) => feed.revokes_binary(bytes),
        _ => None,
    };
    let allow_downgrade = paths.allow_downgrade || revoked_installed.is_some();
    let marker_skipped = match controller {
        None => NO_CONTROLLER.to_owned(),
        Some(ctl) => match ctl.marker(channel, paths.target).await {
            Err(why) => why,
            Ok(marker)
                if let Some(why) = feed
                    .as_ref()
                    .ok()
                    .and_then(|f| f.revokes(&marker.sha256, Some(marker.commit.as_str()))) =>
            {
                format!("the marker names a revoked build ({why})")
            }
            Ok(marker) => {
                let picked = Picked {
                    source: Source::Controller,
                    marker_skipped: None,
                    kept_installed: None,
                };
                let sha = marker.sha256.clone();
                let from = Origin::Controller(ctl);
                match choose(paths, fetch, &downloads, installed.as_deref(), &sha, from).await? {
                    Ok(Some(step)) => {
                        return Ok(Prepared::Ready(Plan {
                            commit: marker.commit,
                            sha256: sha,
                            step,
                            rd,
                            picked,
                            allow_downgrade,
                            revoked_installed,
                            tui_source,
                            dir: downloads.join(&marker.sha256),
                            lease,
                        }));
                    }
                    Ok(None) => return Ok(Prepared::RolledBackBefore(marker.commit, rd, picked)),
                    Err(why) => why,
                }
            }
        },
    };
    // Neither source can be read: the update fails, nothing changed.
    let feed = feed.map_err(|r2| anyhow!("{r2}; and the controller's marker: {marker_skipped}"))?;
    let mut picked =
        Picked { source: Source::R2, marker_skipped: Some(marker_skipped), kept_installed: None };
    let sha = feed.sha256_for(paths.target)?.to_owned();
    // The controller's build of a commit has another sha256 than R2's build
    // of it (another profile): an installed build of the channel's commit,
    // most likely the marker's, is kept, not swapped for R2's every run the
    // controller is down. One of a newer commit is kept by `apply`
    // (`newerInstalled`). `--allow-downgrade` installs R2's build anyway.
    let ours = installed.as_deref().filter(|_| !allow_downgrade);
    if let Some(bytes) = ours
        && let Some(why) = same_commit(bytes, &feed.commit, None)
    {
        picked.kept_installed = Some(why);
        return kept(paths, &downloads, bytes, feed.commit, rd, picked, tui_source, lease);
    }
    let from = Origin::R2(&feed);
    let step = match choose(paths, fetch, &downloads, installed.as_deref(), &sha, from).await? {
        Ok(Some(step)) => step,
        Ok(None) => return Ok(Prepared::RolledBackBefore(feed.commit, rd, picked)),
        // The R2 path has no lookup that can fall back.
        Err(why) => bail!(why),
    };
    // The R2 binary may carry an older commit of the same tree than the
    // channel's: compare the downloaded one's too.
    if let (Some(bytes), Step::Install(dir)) = (ours, &step) {
        let r2s = std::fs::read(dir.join(format!("acpmux-{}", paths.target))).ok();
        if let Some(why) =
            r2s.as_deref().and_then(|r2s| same_commit(bytes, &feed.commit, Some(r2s)))
        {
            picked.kept_installed = Some(why);
            return kept(paths, &downloads, bytes, feed.commit, rd, picked, tui_source, lease);
        }
    }
    Ok(Prepared::Ready(Plan {
        commit: feed.commit,
        dir: downloads.join(&sha),
        sha256: sha,
        step,
        rd,
        picked,
        allow_downgrade,
        revoked_installed,
        tui_source,
        lease,
    }))
}

/// Why `installed` is the same commit's build as the R2 channel's: its
/// embedded commit is `channel_commit`'s, or (`r2s`) the one R2's binary
/// carries. None when its commit is unknown or another.
fn same_commit(installed: &[u8], channel_commit: &str, r2s: Option<&[u8]>) -> Option<String> {
    let build = embedded_build(installed)?;
    let ours = build_commit(&build)?;
    let theirs = match r2s {
        None => channel_commit.to_owned(),
        Some(bytes) => build_commit(&embedded_build(bytes)?)?.to_owned(),
    };
    let same = theirs.starts_with(ours) || ours.starts_with(&theirs);
    same.then(|| {
        format!(
            "the installed build ({build}) is of the commit of the R2 channel's build ({theirs}), so it is kept"
        )
    })
}

/// A plan that keeps the installed binary ([`Step::Current`], its own
/// download folder): the update still finishes a restart an earlier run left.
#[allow(clippy::too_many_arguments)]
fn kept(
    paths: &Paths,
    downloads: &Path,
    bytes: &[u8],
    commit: String,
    rd: RdOutcome,
    picked: Picked,
    tui_source: Result<TuiSource, String>,
    lease: Lease,
) -> Result<Prepared> {
    let sha = crate::sha256::sha256_hex(bytes);
    let dir = downloads.join(&sha);
    keep(&dir, paths.target, bytes)?;
    Ok(Prepared::Ready(Plan {
        commit,
        sha256: sha,
        step: Step::Current(embedded_build(bytes)),
        rd,
        picked,
        allow_downgrade: paths.allow_downgrade,
        revoked_installed: None,
        tui_source,
        dir,
        lease,
    }))
}

/// Why the marker was not read on a host that names no controller.
const NO_CONTROLLER: &str =
    "no build controller is configured (CMUX_CI_CONTROLLER or the fleet client's client.json)";

/// Where a build's binary is downloaded from.
enum Origin<'a> {
    /// The R2 tree the channel names.
    R2(&'a Channel),
    /// The URL the controller gives for the sha256.
    Controller(&'a Controller<'a>),
}

/// The step for the build whose sha256 is `sha`: `Ok(Some)` current or
/// downloaded and checked, `Ok(None)` rolled back here before, `Err(why)` the
/// controller could not say where the binary is (the caller falls back to
/// R2). The outer error (a download that does not match, a disk that cannot
/// hold it) fails the update with nothing installed.
async fn choose(
    paths: &Paths,
    fetch: &dyn Fetch,
    downloads: &Path,
    installed: Option<&[u8]>,
    sha: &str,
    from: Origin<'_>,
) -> Result<Result<Option<Step>, String>> {
    let installed_sha = installed.map(crate::sha256::sha256_hex);
    prune(downloads, &[Some(sha), installed_sha.as_deref()]);
    let dir = downloads.join(sha);
    match installed {
        Some(bytes) if crate::sha256::sha256_hex(bytes) == sha => {
            keep(&dir, paths.target, bytes)?;
            return Ok(Ok(Some(Step::Current(embedded_build(bytes)))));
        }
        _ if dir.join(ROLLED_BACK).is_file() => return Ok(Ok(None)),
        _ => {}
    }
    if downloaded(&dir, paths.target, sha) {
        return Ok(Ok(Some(Step::Install(dir))));
    }
    let (url, whose) = match from {
        Origin::R2(feed) => {
            let url = feed.binary_url(paths.target);
            if let Some(bytes) = smaller(fetch, &url, installed, sha).await {
                keep(&dir, paths.target, &bytes)?;
                return Ok(Ok(Some(Step::Install(dir))));
            }
            (url, "the channel's")
        }
        Origin::Controller(ctl) => match ctl.binary_url(sha).await {
            Ok(url) => (url, "the controller's marker's"),
            Err(why) => return Ok(Err(why)),
        },
    };
    Ok(Ok(Some(Step::Install(download(fetch, &url, whose, paths.target, sha, downloads).await?))))
}

/// Whether `unit` is acpmux's own `acpmux.service` ([`is_own_unit`]): a regular
/// file, not a link. On a cmux Cloud VM only that daemon is this host's to
/// update; the update's probe then checks the daemon runs under it
/// (`cloud_vm_check`, `host_update.rs`).
fn own_unit(unit: &Path) -> bool {
    std::fs::symlink_metadata(unit).is_ok_and(|m| m.file_type().is_file())
        && std::fs::read(unit).is_ok_and(|text| is_own_unit(&text))
}

/// Remove the download folders (`<sha256>/`) of builds other than `keep`
/// (the chosen build, and the installed one, which a run that keeps it
/// holds there), except a rolled-back build's [`ROLLED_BACK`] marker: only
/// its binary goes, so the channel moving on and back never installs that
/// build again.
fn prune(downloads: &Path, keep: &[Option<&str>]) {
    let Ok(entries) = std::fs::read_dir(downloads) else { return };
    for entry in entries.flatten() {
        let name = entry.file_name();
        if !name.to_str().is_some_and(|n| !keep.contains(&Some(n)) && lower_hex(n, 64)) {
            continue;
        }
        let dir = entry.path();
        if !dir.join(ROLLED_BACK).is_file() {
            let _ = crate::home_fs::remove_dir_all(&dir);
            continue;
        }
        for file in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
            if file.file_name() != ROLLED_BACK {
                let _ = crate::home_fs::remove_file(file.path());
            }
        }
    }
}

/// Whether a run before left `dir/acpmux-<target>` with sha256 `sha`.
fn downloaded(dir: &Path, target: &str, sha: &str) -> bool {
    let path = dir.join(format!("acpmux-{target}"));
    std::fs::read(&path).is_ok_and(|bytes| crate::sha256::sha256_hex(&bytes) == sha)
}

/// `downloads/<sha>/acpmux-<target>`, downloaded from `url`; a body whose
/// sha256 is not `sha` (`whose` names where `sha` came from) is never
/// written. The folder.
async fn download(
    fetch: &dyn Fetch,
    url: &str,
    whose: &str,
    target: &str,
    sha: &str,
    downloads: &Path,
) -> Result<PathBuf> {
    let dir = downloads.join(sha);
    let bytes =
        fetch.get(url, BINARY_MAX_BYTES).await.map_err(|e| anyhow!("downloading {url}: {e}"))?;
    let got = crate::sha256::sha256_hex(&bytes);
    if got != sha {
        bail!("{url} has sha256 {got}, not {whose} {sha}, so it is not installed");
    }
    keep(&dir, target, &bytes)?;
    Ok(dir)
}

/// The largest window a published patch or `.zst` may use (`zstd --long=31`).
const ZSTD_WINDOW_LOG_MAX: u32 = 31;

/// The channel's binary rebuilt from one of the smaller files published
/// beside `url` (RFD 0166, "Cloud machine and acpmux binary updates"): a
/// patch against the installed build (`<url>.from-<installed sha256>.zst`,
/// `zstd --patch-from`, about a tenth of the binary) when there is one, else
/// the whole binary compressed (`<url>.zst`, about a third). None when
/// neither is there, decodes, or rebuilds a binary of sha256 `sha`: the
/// caller then downloads the binary itself, so a missing or bad file costs a
/// request, never the update.
async fn smaller(
    fetch: &dyn Fetch,
    url: &str,
    installed: Option<&[u8]>,
    sha: &str,
) -> Option<Vec<u8>> {
    let mut tries: Vec<(String, &[u8])> = Vec::new();
    if let Some(old) = installed {
        tries.push((format!("{url}.from-{}.zst", crate::sha256::sha256_hex(old)), old));
    }
    tries.push((format!("{url}.zst"), &[]));
    for (url, old) in tries {
        let Ok(packed) = fetch.get(&url, BINARY_MAX_BYTES).await else { continue };
        match unpack(&packed, old) {
            Ok(bytes) if crate::sha256::sha256_hex(&bytes) == sha => return Some(bytes),
            _ => continue,
        }
    }
    None
}

/// `packed` decoded, against `old` (a raw-content dictionary: what
/// `--patch-from` encoded against) when it is not empty; at most
/// [`BINARY_MAX_BYTES`].
pub(super) fn unpack(packed: &[u8], old: &[u8]) -> std::io::Result<Vec<u8>> {
    use std::io::Read;
    let mut decoder = zstd::stream::read::Decoder::with_dictionary(packed, old)?;
    decoder.window_log_max(ZSTD_WINDOW_LOG_MAX)?;
    let mut bytes = Vec::new();
    decoder.take(BINARY_MAX_BYTES as u64 + 1).read_to_end(&mut bytes)?;
    if bytes.len() > BINARY_MAX_BYTES {
        return Err(std::io::Error::other("above the binary limit"));
    }
    Ok(bytes)
}

/// `dir/acpmux-<target>` holds `bytes` (already checked), written beside and
/// renamed; a copy with these bytes already there is kept.
fn keep(dir: &Path, target: &str, bytes: &[u8]) -> Result<()> {
    let path = dir.join(format!("acpmux-{target}"));
    if std::fs::read(&path).is_ok_and(|have| have == bytes) {
        return Ok(());
    }
    crate::home_fs::create_dirs(dir).with_context(|| format!("creating {}", dir.display()))?;
    let part = dir.join(format!(".acpmux-{target}.part"));
    crate::home_fs::write(&part, bytes).with_context(|| format!("writing {}", part.display()))?;
    #[cfg(unix)]
    crate::home_fs::set_mode(&part, 0o755)?;
    crate::home_fs::rename(&part, &path).with_context(|| format!("writing {}", path.display()))?;
    Ok(())
}

/// Carry out `plan` on `remote` (this machine), every script fenced for its
/// lease: the row `host update` prints for a peer. Either step goes through
/// [`update_peer`], which leaves a daemon already on the channel's build
/// alone and restarts one that is not, so an update stopped between the
/// install and the restart is finished by the next run (review of #24232). A
/// build whose daemon was rolled back is marked, so the next run leaves it
/// alone (a restart that failed before the build was checked is not
/// marked); when the mark cannot be written, the row says so. Unless `now`, a
/// daemon an update restarted within the host's restart window (this timer's
/// or a `host update` from another machine: one stamp on the host) is left
/// alone, and nothing is installed: the first run after the window brings
/// the newest build.
pub(super) fn apply(
    remote: &dyn Remote,
    plan: &Plan,
    target: &'static str,
    now: bool,
) -> PeerUpdate {
    let (dir, installed) = match &plan.step {
        Step::Current(build) => (&plan.dir, build.as_deref()),
        Step::Install(dir) => (dir, None),
    };
    let opts = UpdateOptions {
        binary_dir: Some(dir.clone()),
        if_idle: false,
        keep_newer: false,
        // Newer wins: a host whose installed build is of a newer commit than
        // the channel's keeps it (`current`, reason `newerInstalled`), as it
        // keeps it against a push from elsewhere. A lane's branch build or a
        // hand-pushed one that contains the channel's head is never rolled
        // back to it by this timer (the lane hosts of 2026-11-23 held
        // b45cad3d8 while the channel sat at 7d439038 and the timer kept
        // trying to put that back, each try a restart). `--allow-downgrade`
        // is how a bad channel build is deliberately pulled back.
        allow_downgrade: plan.allow_downgrade,
        caller: None,
        now,
    };
    let fenced = plan.lease.fence(remote);
    let mut up = update_peer(&fenced, &opts);
    if !now && up.outcome == Outcome::Busy && up.reason.as_deref() == Some(RESTART_WINDOW) {
        up = idle_restart(&fenced, &opts, up);
    }
    up.target.get_or_insert(target);
    if up.outcome == Outcome::Current && up.build.is_none() {
        up.build = installed.map(str::to_owned);
    }
    // Only a verdict on the build marks it: its daemon did not answer, or
    // answered on another build. A restart script that failed (`restartFailed`:
    // the old daemon was still stopping, the unit was mid-restart) never got
    // to check the build, so the next run tries it again: three fleet hosts
    // (2026-11-23) marked a good build rolled back for good on such
    // a failure and then sat on the old build, every run "waiting for a newer
    // one". The restart window keeps that retry to once an hour.
    if up.outcome == Outcome::RolledBack && up.reason.as_deref() != Some("restartFailed") {
        let mark = dir.join(ROLLED_BACK);
        if let Err(e) = crate::home_fs::write(&mark, up.error.as_deref().unwrap_or("")) {
            let why = up.error.take().unwrap_or_default();
            up.error = Some(format!(
                "{why}; marking the build rolled back failed ({}: {e}), so the next run tries it again",
                mark.display()
            ));
        }
    }
    up
}

/// After acpmux's step (`up`), bring the cmux-tui beside acpmux ([`Paths::tui`]) to the R2
/// channel's tree ([`tui::refresh`]), still under the plan's lease. Only when that step left the
/// channel's build running: `updated`, or `current` but not on a newer installed build; a
/// rollback, failure or held restart leaves cmux-tui with the acpmux that still runs.
pub(super) async fn refresh_tui(
    paths: &Paths,
    fetch: &dyn Fetch,
    plan: &Plan,
    up: &PeerUpdate,
) -> TuiOutcome {
    let Some(tui) = &paths.tui else { return TuiOutcome::Absent };
    let follows = match up.outcome {
        Outcome::Updated => true,
        Outcome::Current => up.reason.as_deref() != Some(super::NEWER_INSTALLED),
        _ => false,
    };
    if !follows {
        if !tui.is_file() {
            return TuiOutcome::Absent;
        }
        let reason = up.reason.as_deref().map(|r| format!(", {r}")).unwrap_or_default();
        return TuiOutcome::Skipped(format!("acpmux's step was {}{reason}", up.outcome.as_str()));
    }
    tui::refresh(tui, fetch, &plan.tui_source, paths.target).await
}

/// The file in [`REMOTE_HOME`] that turns [`idle_restart`] off when it says
/// `0` (else `ACPMUX_UPDATE_IDLE_RESTART` in the timer's environment).
pub(crate) const IDLE_RESTART_FILE: &str = "update.idle-restart";

/// The file in [`REMOTE_HOME`] that holds when (the host's `date +%s`) the
/// last idle restart was made.
pub(crate) const IDLE_RESTARTED_FILE: &str = "update.idle-restarted";

/// Starts the line [`idle_state`] reads.
const IDLE_STATE: &str = "ACPMUX_IDLE_STATE=";

/// The host's idle-restart switch, restart stamp, and whether an idle
/// restart is due (none yet, or the last one at least the window ago, the
/// window as the restart window's own file, then the timer's
/// [`RESTART_WINDOW_ENV`], else [`RESTART_WINDOW_SECS`]; a time from the
/// future counts as due): `(off, due, stamp)`.
fn idle_state(remote: &dyn Remote) -> Option<(bool, bool, String)> {
    let script = format!(
        r#"v=$(cat {REMOTE_HOME}/{IDLE_RESTART_FILE} 2>/dev/null | tr -cd '0-9a-z')
[ -n "$v" ] || v=$(printf '%s' "${{ACPMUX_UPDATE_IDLE_RESTART-}}" | tr -cd '0-9a-z')
[ "$v" = 0 ] && o=off || o=on
s=$(cat {REMOTE_HOME}/{RESTART_STAMP} 2>/dev/null | tr -cd '0-9')
d=$(cat {REMOTE_HOME}/{IDLE_RESTARTED_FILE} 2>/dev/null | tr -cd '0-9')
w=$(cat {REMOTE_HOME}/{RESTART_WINDOW_FILE} 2>/dev/null | tr -cd '0-9')
[ -n "$w" ] || w=$(printf '%s' "${{{RESTART_WINDOW_ENV}-}}" | tr -cd '0-9')
[ -n "$w" ] || w={RESTART_WINDOW_SECS}
n=$(date +%s); due=due
if [ -n "$d" ] && [ "$d" -le "$n" ] && [ $((n - d)) -lt "$w" ]; then due=wait; fi
echo "{IDLE_STATE}$o $due ${{s:-0}}"
"#
    );
    let out = remote.exec(&script, None).ok()?;
    let line = out.stdout.lines().find_map(|l| l.strip_prefix(IDLE_STATE))?;
    let mut words = line.split(' ');
    let off = words.next()? == "off";
    let due = words.next()? == "due";
    Some((off, due, words.next()?.to_owned()))
}

/// The restart window held the daemon (`up`, busy `restartWindow`): the
/// window bounds a FORCED restart, but a daemon that is idle has nothing to
/// wake, so the update goes in now, at the first run that finds no session
/// mid-turn or waiting on a permission (`if_idle`: read before the copy and
/// again right before the restart, and the binary goes back when a turn
/// started). A run that finds one busy leaves `up` (busy, `restartWindow`):
/// the window's forced restart applies as before, and a later run that finds
/// the daemon idle takes this path again. This path always installs the
/// channel's newest build, so moves that landed while it waited are one
/// restart. Idle restarts are at least a window apart: one writes the host's
/// time to [`IDLE_RESTARTED_FILE`] (the early restart stamps the window too,
/// so counting from the stamp would let one restart follow another), and
/// the next waits until a window has passed since. Together with the
/// window (measured from the last restart of any kind) that is at most one
/// restart per host per hour amortized, and 2 in any rolling hour. Off with
/// `0` in [`IDLE_RESTART_FILE`] or `ACPMUX_UPDATE_IDLE_RESTART`.
fn idle_restart(remote: &dyn Remote, opts: &UpdateOptions, held: PeerUpdate) -> PeerUpdate {
    let Some((false, true, stamp)) = idle_state(remote) else {
        return held;
    };
    let early = UpdateOptions {
        binary_dir: opts.binary_dir.clone(),
        if_idle: true,
        keep_newer: opts.keep_newer,
        allow_downgrade: opts.allow_downgrade,
        caller: None,
        now: true,
    };
    let up = update_peer(remote, &early);
    if let Some((_, _, after)) = idle_state(remote)
        && after != stamp
    {
        let file = format!("{REMOTE_HOME}/{IDLE_RESTARTED_FILE}");
        let write = format!("(umask 077 && date +%s > {file}.$$ && mv -f {file}.$$ {file})");
        let _ = remote.exec(&write, None);
    }
    match (up.outcome, up.reason.as_deref()) {
        // Mid-turn: the window's answer stands, as it reads to the person.
        (Outcome::Busy, Some("busy" | "unknown")) => held,
        _ => up,
    }
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
/// `--json` prints `{"channel", "commit", "sha256", "source", "markerSkipped",
/// "updated": [ROW]}`: `source` is `controller` (the build controller's
/// marker) or `r2` (the channel file), `markerSkipped` says why the marker
/// was not used, and `keptInstalled` why an installed build of the R2
/// channel's commit (most likely the controller's) was kept; `cmuxRd` and `cmuxTui`
/// (`{"outcome", "message"}`) say what happened to cmux-rd and to the cmux-tui beside acpmux
/// (`host_self_update_tui.rs`), never failing the row. With automatic updates off, another update of this
/// host running, or the chosen build rolled back here before, nothing
/// happens: `{"channel", "skipped": "off" | "locked" | "rolledBack",
/// "message", "updated": []}` (`rolledBack` with `source` and
/// `markerSkipped` too), exit 0.
/// Exits 1 when the row failed. The channel decides, newer wins: a build pushed
/// by hand with `host update` is replaced by the channel's at the next run,
/// unless automatic updates are off or the installed build is of a newer
/// commit than the channel's (`--allow-downgrade` replaces that too).
///
/// `fast_patch` (`--fast-patch [--commit SHA]`, RFD 0060; see
/// [`fast_patch`]): the run is the same update with `now` (no restart
/// window), refused when `SHA` is given and the channel names another
/// commit, and it appends one line to the fast-patch runs file; `--json`
/// carries the line as `fastPatch` once the update ran.
pub(crate) async fn self_update(
    channel: &str,
    now: bool,
    allow_downgrade: bool,
    fast_patch: Option<Option<String>>,
    json_out: bool,
) -> Result<()> {
    if std::env::consts::OS != "linux" {
        bail!(
            "host self-update keeps a Linux host's own daemon updated; update another machine with `acpmux machine update NAME`"
        );
    }
    let now = now || fast_patch.is_some();
    let paths = Paths::here(now, allow_downgrade)?;
    let mut run = fast_patch.map(|asked| fast_patch::Run::start(asked, &paths.installed));
    // A run that changed nothing: its line (stderr says so), then the
    // update's own answer on stdout.
    let refuse = |run: Option<fast_patch::Run>, why: &str| {
        if let Some(run) = run {
            run.finish("refused", why);
            eprintln!("acpmux: fast-patch refused: {why}");
        }
    };
    let controller =
        Controller::configured().map(|url| Controller { url, fetch: &CONTROLLER_FETCH });
    let prepared = match prepare(&paths, &R2_FETCH, controller.as_ref(), channel).await {
        Ok(prepared) => prepared,
        Err(e) => {
            refuse(run, &format!("{e:#}"));
            return Err(e);
        }
    };
    let plan = match prepared {
        Prepared::Off => {
            let why = format!(
                "automatic updates are off on this host (remove {} to turn them on)",
                paths.off.display()
            );
            refuse(run, &why);
            return skipped(channel, "off", &why, None, json_out);
        }
        Prepared::Locked => {
            let why = "another update of this host is running (a host update, or this timer)";
            refuse(run, why);
            return skipped(channel, "locked", why, None, json_out);
        }
        Prepared::RolledBackBefore(commit, rd, picked) => {
            let why = format!(
                "the {channel} build of commit {commit} ({}) was rolled back on this host before; waiting for a newer one",
                picked.source.name()
            );
            if let Some(run) = run.as_mut() {
                let _ = run.check_commit(&commit);
            }
            refuse(run, &why);
            print_rd(&rd, json_out);
            crate::update_inventory::record_in(
                &paths.home,
                json!({
                    "channel": channel, "commit": commit, "source": picked.source.name(),
                    "skipped": "rolledBack", "message": why, "build": installed_build(&paths.installed),
                    "prevBuild": installed_build(&prev_of(&paths.installed)),
                }),
            );
            return skipped(channel, "rolledBack", &why, Some(&picked), json_out);
        }
        Prepared::Ready(plan) => plan,
    };
    if let Some(r) = run.as_mut()
        && let Err(why) = r.check_commit(&plan.commit)
    {
        // Nothing installed: dropping the plan releases the update lock.
        refuse(run, &why);
        bail!("fast-patch refused: {why}");
    }
    let up = apply(&LocalRemote, &plan, paths.target, now || plan.revoked_installed.is_some());
    crate::update_inventory::record_in(
        &paths.home,
        inventory_run(channel, &plan, &up, &paths.installed),
    );
    let tui = refresh_tui(&paths, &R2_FETCH, &plan, &up).await;
    let name = crate::hand::pair::hostname();
    let fast_patch_line = run.map(|run| {
        let line = run.finish(fast_patch::outcome(&up), &fast_patch::detail(&up));
        eprintln!(
            "acpmux: fast-patch {} {}: {} in {} s",
            fast_patch::SERVICE,
            plan.commit.get(..12).unwrap_or(&plan.commit),
            line.get("outcome").and_then(|v| v.as_str()).unwrap_or_default(),
            line.get("seconds").cloned().unwrap_or_default()
        );
        line
    });
    if json_out {
        print_json(&json!({
            "fastPatch": fast_patch_line,
            "channel": channel,
            "commit": plan.commit,
            "sha256": plan.sha256,
            "source": plan.picked.source.name(),
            "markerSkipped": plan.picked.marker_skipped,
            "keptInstalled": plan.picked.kept_installed,
            "updated": [up.to_json(&name, LocalRemote.host())],
            "cmuxRd": plan.rd.json(),
            "cmuxTui": tui.json(),
        }));
    } else {
        if up.outcome.failed() {
            eprintln!("{name} (local): {}", up.line());
        } else {
            println!("{name} (local): {}", up.line());
        }
        print_rd(&plan.rd, false);
        if let Some(line) = tui.line() {
            println!("{line}");
        }
    }
    if up.outcome.failed() {
        // crash-allow: the row above is the whole output; exit 1 is the documented failure code, as in `host update`
        std::process::exit(1);
    }
    Ok(())
}

/// The build a binary on disk carries, when it can be read.
fn installed_build(path: &Path) -> Option<String> {
    std::fs::read(path).ok().as_deref().and_then(embedded_build)
}

/// `acpmux.prev` beside `installed`: the build an update replaced, kept for its rollback.
fn prev_of(installed: &Path) -> PathBuf {
    let mut name = installed.file_name().unwrap_or_default().to_os_string();
    name.push(".prev");
    installed.with_file_name(name)
}

/// One run's row in the host's version inventory ([`crate::update_inventory`]).
pub(super) fn inventory_run(
    channel: &str,
    plan: &Plan,
    up: &PeerUpdate,
    installed: &Path,
) -> serde_json::Value {
    json!({
        "channel": channel,
        "commit": plan.commit,
        "sha256": plan.sha256,
        "source": plan.picked.source.name(),
        "outcome": up.outcome.as_str(),
        "reason": up.reason,
        "error": up.error,
        "build": up.build,
        "prevBuild": installed_build(&prev_of(installed)),
        "revokedInstalled": plan.revoked_installed,
    })
}

/// cmux-rd's line, when there is one to print (`--json` carries it as `cmuxRd`).
fn print_rd(rd: &RdOutcome, json_out: bool) {
    if !json_out && let Some(line) = rd.line() {
        println!("{line}");
    }
}

fn skipped(
    channel: &str,
    why: &str,
    message: &str,
    picked: Option<&Picked>,
    json_out: bool,
) -> Result<()> {
    if json_out {
        let mut out =
            json!({"channel": channel, "skipped": why, "message": message, "updated": []});
        if let (Some(picked), Some(obj)) = (picked, out.as_object_mut()) {
            obj.extend(picked.json().as_object().cloned().unwrap_or_default());
        }
        print_json(&out);
    } else {
        println!("{message}");
    }
    Ok(())
}
