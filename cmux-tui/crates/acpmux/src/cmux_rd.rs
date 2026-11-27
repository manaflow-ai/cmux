//! Screen sharing on a joined Linux machine with no step on it (cmuxterm-hq
//! docs/design/remote-screen-share-zero-touch.md, L1 and row L-b): the daemon installs the
//! pinned `cmux-rd` (the `cmux-rd-vX.Y.Z` release for this target, checked against [`PIN`]'s
//! sha256) at `~/.local/bin/cmux-rd`, and runs `cmux-rd linux-host enable --non-interactive`
//! with `ACPMUX_HOME` set to its home, once per installed version.
//!
//! - Only on Linux, only on a box joined here ([`Join`]): a home copied from another box, a
//!   revoked or left join, or a join to a loopback (test) hub is skipped.
//! - Only `x86_64` has a release build; another target is skipped and logged.
//! - The archive is refused unless its sha256 is the pinned one, and nothing is written then.
//!   The binary goes in with one rename, and [`RECORD`] in the daemon's home names what was
//!   installed (version, archive sha256, binary sha256) and the archive whose `enable` ran.
//! - It never fails the daemon or the join: it runs on its own thread after the daemon starts
//!   ([`spawn_at_daemon_start`]), waits for a join that completes while the daemon runs, logs
//!   an error and tries again at the next start.

use std::future::Future;
use std::io::Read as _;
use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};

/// A pinned `cmux-rd` release asset.
#[derive(Clone, Copy, Debug)]
pub struct Pin {
    pub version: &'static str,
    pub url: &'static str,
    /// The lowercase hex sha256 of the `.tar.gz` at `url`.
    pub sha256: &'static str,
}

/// The release this build installs (`.github/workflows/cmux-rd-release.yml`): an x86_64
/// Linux build only.
pub const PIN: Pin = Pin {
    version: "0.2.7",
    url: "https://github.com/manaflow-ai/cmux/releases/download/cmux-rd-v0.2.7/cmux-rd-0.2.7-x86_64-unknown-linux-gnu.tar.gz",
    sha256: "92961c9ebd6b1e7370a6dc1687a3ea864da9c133720daaf51a117aad2f45553d",
};

/// The one architecture [`PIN`] has a build for.
pub const ARCH: &str = "x86_64";
/// What was installed and enabled, in the daemon's home.
pub const RECORD: &str = "cmux-rd.json";
/// The archive's member that is installed.
const MEMBER: [&str; 2] = ["bin", "cmux-rd"];
/// Larger than any release archive or binary; a bigger answer is refused.
const MAX_BYTES: u64 = 256 << 20;
/// How long the download may take.
const FETCH_LIMIT: Duration = Duration::from_secs(300);
/// How long `linux-host enable` may take (it may install a package and start user units).
const ENABLE_LIMIT: Duration = Duration::from_secs(600);
/// How often a daemon on a box that is not joined looks again: the join line starts the
/// service before it redeems the token, so the join completes while the daemon runs.
const JOIN_RECHECK: Duration = Duration::from_secs(30);

/// This box's join, as the install reads it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Join {
    /// No live join of this box: no record, revoked, left, or a loopback (test) hub.
    NotJoined,
    /// The record was joined on another box and copied here.
    Copied,
    Joined,
}

/// What [`ensure`] did.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    NotLinux,
    NotJoined,
    Copied,
    /// No release build for this architecture.
    NoBuild,
    /// The pinned binary is in place and `enable` has run for it; `installed` and `enabled`
    /// say whether this call did either.
    Ready {
        installed: bool,
        enabled: bool,
    },
}

/// Where this box is and where the install goes.
#[derive(Clone, Debug)]
pub struct Place {
    pub os: &'static str,
    pub arch: &'static str,
    pub join: Join,
    /// The daemon's home: `ACPMUX_HOME` for `enable`, and where [`RECORD`] goes.
    pub home: PathBuf,
    /// `~/.local/bin/cmux-rd`.
    pub bin: PathBuf,
}

/// [`RECORD`].
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Record {
    pub version: String,
    pub archive_sha256: String,
    pub binary_sha256: String,
    pub path: PathBuf,
    /// The archive whose binary `linux-host enable --non-interactive` last succeeded for.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub enabled_sha256: Option<String>,
}

/// The network and the process [`ensure`] uses: the daemon's real ones ([`Live`]), or a test's.
pub trait Host {
    /// The bytes at `url`.
    fn fetch(&self, url: &str) -> impl Future<Output = Result<Vec<u8>>> + Send;
    /// `bin linux-host enable --non-interactive` with `ACPMUX_HOME=home`.
    fn enable(&self, bin: &Path, home: &Path) -> impl Future<Output = Result<()>> + Send;
}

/// This box's join in acpmux home `home`.
pub fn join_state(home: &Path) -> Join {
    if !matches!(crate::machine_record::load_at(home), Ok(Some(_))) {
        return Join::NotJoined;
    }
    if crate::cli::cloud_join::copied_from_another_box_at(home) {
        return Join::Copied;
    }
    match crate::cli::cloud_join::joined_device_at(home) {
        Some(device) if !loopback(&device.hub_origin) => Join::Joined,
        _ => Join::NotJoined,
    }
}

/// Whether `origin` is a hub on this box (a test's): never a join to install for.
fn loopback(origin: &str) -> bool {
    reqwest::Url::parse(origin).ok().is_some_and(|url| {
        matches!(url.host_str(), Some("localhost" | "127.0.0.1" | "[::1]" | "::1"))
    })
}

/// This box, for the daemon whose home is `home`.
pub fn here(home: &Path) -> Place {
    Place {
        os: std::env::consts::OS,
        arch: std::env::consts::ARCH,
        join: join_state(home),
        home: home.to_owned(),
        bin: dirs::home_dir().unwrap_or_else(|| PathBuf::from(".")).join(".local/bin/cmux-rd"),
    }
}

/// The record in `home`, when there is one that reads.
pub fn record(home: &Path) -> Option<Record> {
    let bytes = std::fs::read(home.join(RECORD)).ok()?;
    serde_json::from_slice(&bytes).ok()
}

fn save(home: &Path, record: &Record) -> Result<()> {
    crate::home_fs::write(home.join(RECORD), serde_json::to_vec_pretty(record)?)
        .with_context(|| format!("write {}", home.join(RECORD).display()))
}

/// Whether `record` names `pin`'s archive and the binary at `bin` is the one it installed.
fn installed(record: Option<&Record>, pin: &Pin, bin: &Path) -> bool {
    record.is_some_and(|r| {
        r.version == pin.version
            && r.archive_sha256 == pin.sha256
            && r.path == bin
            && std::fs::read(bin)
                .is_ok_and(|bytes| crate::sha256::sha256_hex(&bytes) == r.binary_sha256)
    })
}

/// Makes `place.bin` the binary of `pin` and runs `enable` once for it. Skips (with the
/// reason as the outcome) off Linux, on a box not joined here, and on a target with no build.
pub async fn ensure(place: &Place, pin: &Pin, host: &impl Host) -> Result<Outcome> {
    if place.os != "linux" {
        return Ok(Outcome::NotLinux);
    }
    match place.join {
        Join::NotJoined => return Ok(Outcome::NotJoined),
        Join::Copied => return Ok(Outcome::Copied),
        Join::Joined => {}
    }
    if place.arch != ARCH {
        return Ok(Outcome::NoBuild);
    }
    let mut current = record(&place.home);
    let installed_now = !installed(current.as_ref(), pin, &place.bin);
    if installed_now {
        let archive = host.fetch(pin.url).await?;
        let got = crate::sha256::sha256_hex(&archive);
        if got != pin.sha256 {
            bail!("cmux-rd archive sha256 mismatch: expected {}, got {got}", pin.sha256);
        }
        let binary = member(&archive)?;
        install(&place.bin, &binary)?;
        let fresh = Record {
            version: pin.version.to_owned(),
            archive_sha256: pin.sha256.to_owned(),
            binary_sha256: crate::sha256::sha256_hex(&binary),
            path: place.bin.clone(),
            // The same archive put back (its binary changed or moved): `enable` ran for it.
            enabled_sha256: current
                .as_ref()
                .and_then(|r| r.enabled_sha256.clone())
                .filter(|sha| sha == pin.sha256),
        };
        save(&place.home, &fresh)?;
        current = Some(fresh);
    }
    let mut current = current.unwrap_or_default();
    let enable_now = current.enabled_sha256.as_deref() != Some(pin.sha256);
    if enable_now {
        host.enable(&place.bin, &place.home).await?;
        current.enabled_sha256 = Some(pin.sha256.to_owned());
        save(&place.home, &current)?;
    }
    Ok(Outcome::Ready { installed: installed_now, enabled: enable_now })
}

/// The bytes of `bin/cmux-rd` in the gzipped tar `archive` (at its root or under one folder).
fn member(archive: &[u8]) -> Result<Vec<u8>> {
    let mut tar = tar::Archive::new(flate2::read::GzDecoder::new(archive));
    for entry in tar.entries()? {
        let entry = entry?;
        if !entry.header().entry_type().is_file() {
            continue;
        }
        let path = entry.path()?.into_owned();
        let names: Vec<_> = path
            .components()
            .filter_map(|c| match c {
                std::path::Component::Normal(name) => Some(name.to_string_lossy().into_owned()),
                _ => None,
            })
            .collect();
        if !names.ends_with(&MEMBER.map(str::to_owned)) {
            continue;
        }
        let mut bytes = Vec::new();
        entry.take(MAX_BYTES + 1).read_to_end(&mut bytes)?;
        if bytes.len() as u64 > MAX_BYTES {
            bail!("cmux-rd binary in the archive is larger than {MAX_BYTES} bytes");
        }
        return Ok(bytes);
    }
    bail!("cmux-rd archive has no bin/cmux-rd")
}

/// Puts `binary` at `bin`, executable, with one rename: a running `cmux-rd` keeps its file.
fn install(bin: &Path, binary: &[u8]) -> Result<()> {
    let dir = bin.parent().context("cmux-rd path has no folder")?;
    crate::home_fs::create_dirs(dir).with_context(|| format!("make {}", dir.display()))?;
    let staged = dir.join(format!(".cmux-rd.{}.partial", std::process::id()));
    let placed = (|| -> std::io::Result<()> {
        crate::home_fs::write(&staged, binary)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            crate::home_fs::set_permissions(&staged, std::fs::Permissions::from_mode(0o755))?;
        }
        crate::home_fs::rename(&staged, bin)?;
        crate::home_fs::sync_dir(dir)
    })();
    if let Err(e) = placed {
        let _ = crate::home_fs::remove_file(&staged);
        return Err(e).with_context(|| format!("install {}", bin.display()));
    }
    Ok(())
}

/// The daemon's network and processes.
pub struct Live;

impl Host for Live {
    async fn fetch(&self, url: &str) -> Result<Vec<u8>> {
        // GitHub answers a release download with a redirect to its object store
        // (both hosts are in cmux-egress/hosts.txt).
        let client =
            cmux_egress::client_builder("acpmux::cmux_rd::fetch").timeout(FETCH_LIMIT).build()?;
        let mut answer = client.get(url).send().await?.error_for_status()?;
        let mut bytes = Vec::new();
        while let Some(chunk) = answer.chunk().await? {
            bytes.extend_from_slice(&chunk);
            if bytes.len() as u64 > MAX_BYTES {
                bail!("cmux-rd archive is larger than {MAX_BYTES} bytes");
            }
        }
        Ok(bytes)
    }

    async fn enable(&self, bin: &Path, home: &Path) -> Result<()> {
        let mut command = tokio::process::Command::new(bin);
        command
            .args(["linux-host", "enable", "--non-interactive"])
            .env("ACPMUX_HOME", home)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true);
        let output = tokio::time::timeout(ENABLE_LIMIT, command.output())
            .await
            .context("cmux-rd linux-host enable did not finish in time")??;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            let tail: String = stderr.trim().chars().rev().take(600).collect();
            let tail: String = tail.chars().rev().collect();
            bail!("cmux-rd linux-host enable failed ({}): {tail}", output.status);
        }
        Ok(())
    }
}

/// At daemon start: [`ensure`] on its own thread, once this box is joined (looking again every
/// [`JOIN_RECHECK`] until it is). Off Linux it does nothing. An error is logged; the next start
/// tries again.
pub fn spawn_at_daemon_start(home: PathBuf) {
    if !cfg!(target_os = "linux") {
        return;
    }
    let spawned = std::thread::Builder::new().name("cmux-rd-install".into()).spawn(move || {
        let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
            Ok(runtime) => runtime,
            Err(e) => {
                tracing::warn!("cmux-rd install: no runtime: {e}");
                return;
            }
        };
        loop {
            let place = here(&home);
            match runtime.block_on(ensure(&place, &PIN, &Live)) {
                Ok(Outcome::NotJoined) => std::thread::sleep(JOIN_RECHECK),
                Ok(outcome) => {
                    tracing::info!(?outcome, version = PIN.version, "cmux-rd linux host");
                    return;
                }
                Err(e) => {
                    tracing::warn!(
                        version = PIN.version,
                        "cmux-rd linux host not set up (tried again at the next start): {e:#}"
                    );
                    return;
                }
            }
        }
    });
    if let Err(e) = spawned {
        tracing::warn!("cmux-rd install: thread did not start: {e}");
    }
}

#[cfg(test)]
#[path = "cmux_rd_tests.rs"]
mod tests;
