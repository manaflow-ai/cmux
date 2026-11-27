//! An update replaces this image after admission and persistence drain. The same process
//! keeps the home lock and listening sockets; its successor proves readiness with a receipt.
use std::ffi::OsString;
use std::os::fd::{AsFd, AsRawFd, FromRawFd, OwnedFd};
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

use anyhow::{Context, Result, anyhow, ensure};
use serde::{Deserialize, Serialize};

const ENV: &str = "ACPMUX_EXEC_HANDOFF";
pub(crate) const CHECK_ARG: &str = "__exec-update-protocol";
const PROTOCOL: u32 = 1;
static INSTALLED: OnceLock<PathBuf> = OnceLock::new();
static NEEDS_KEY: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
static IMAGE: OnceLock<Image> = OnceLock::new();

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct Image {
    dev: u64,
    ino: u64,
    len: u64,
    modified: i64,
    modified_ns: i64,
    build: String,
}

impl Image {
    fn of(file: &std::fs::File, build: String) -> Result<Self> {
        use std::os::unix::fs::MetadataExt;
        let m = file.metadata()?;
        Ok(Self {
            dev: m.dev(),
            ino: m.ino(),
            len: m.len(),
            modified: m.mtime(),
            modified_ns: m.mtime_nsec(),
            build,
        })
    }
    fn running() -> Result<Self> {
        #[cfg(target_os = "linux")]
        let path = PathBuf::from("/proc/self/exe");
        #[cfg(not(target_os = "linux"))]
        let path = std::env::current_exe()?;
        Self::of(&std::fs::File::open(path)?, crate::hub::build().to_string())
    }
}

/// An older executable rejects this hidden command, without starting or stopping any daemon.
pub(crate) fn check_main() -> Result<()> {
    println!("{}", serde_json::json!({"execProtocol": PROTOCOL, "image": Image::running()?}));
    Ok(())
}

pub(super) fn installed() -> Option<PathBuf> {
    INSTALLED.get().cloned()
}

static PENDING: Mutex<Option<Plan>> = Mutex::new(None);
static RECEIPT: OnceLock<String> = OnceLock::new();

struct Plan {
    program: PathBuf,
    executable: std::fs::File,
    image: Image,
    needs_key: bool,
    args: Vec<String>,
    id: String,
    listeners: Vec<(&'static [u8; 4], OwnedFd)>,
}

#[derive(Serialize, Deserialize)]
struct Manifest {
    pid: u32,
    id: String,
    installed: PathBuf,
    image: Image,
    needs_key: bool,
    lock: i32,
    listeners: Vec<(Vec<u8>, i32)>,
}

pub(super) struct Inherited {
    pub lock: super::lock::DaemonLock,
    pub listeners: super::listener_handover::Received,
}

/// Before children start, seal and validate the explicitly inherited descriptors. An arbitrary
/// environment token alone never becomes a successful-update receipt.
pub(super) fn inherit() -> Result<Option<Inherited>> {
    let Some(raw) = std::env::var_os(ENV) else { return Ok(None) };
    let manifest: Manifest =
        serde_json::from_str(&raw.to_string_lossy()).context("invalid exec handoff manifest")?;
    // Children may inherit the metadata but never its sealed descriptors.
    if manifest.pid != std::process::id() {
        return Ok(None);
    }
    ensure!(Image::running()? == manifest.image, "exec image differs from the checked update");
    ensure!(!manifest.id.is_empty() && manifest.id.len() <= 128, "invalid exec update ID");
    let mut fds = vec![manifest.lock];
    for (kind, fd) in &manifest.listeners {
        ensure!(
            [b"unix".as_slice(), b"ws\0\0", b"egrs"].contains(&kind.as_slice()),
            "invalid inherited listener kind"
        );
        fds.push(*fd);
    }
    let mut unique = fds.clone();
    unique.sort_unstable();
    unique.dedup();
    ensure!(
        fds.iter().all(|fd| *fd > 2) && unique.len() == fds.len(),
        "invalid inherited descriptors"
    );
    for fd in &fds {
        // SAFETY: fcntl validates an integer before it becomes a BorrowedFd.
        ensure!(unsafe { libc::fcntl(*fd, libc::F_GETFD) } >= 0, "inherited descriptor is closed");
    }
    // SAFETY: unique, validated-open descriptors explicitly passed to this image by exec. Seal
    // before taking ownership, so an invalid manifest cannot leak them to startup children.
    let borrowed: Vec<_> =
        fds.iter().map(|fd| unsafe { std::os::fd::BorrowedFd::borrow_raw(*fd) }).collect();
    cmux_process::set_cloexec(&borrowed)?;
    let lock = super::lock::DaemonLock::inherit(
        manifest.lock,
        &crate::config::home().join("daemon.lock"),
    )?;
    let mut listeners = super::listener_handover::Received::default();
    for (kind, fd) in manifest.listeners {
        let mut accepting: libc::c_int = 0;
        let mut len = std::mem::size_of_val(&accepting) as libc::socklen_t;
        // SAFETY: output pointers and their size are valid.
        let rc = unsafe {
            libc::getsockopt(
                fd,
                libc::SOL_SOCKET,
                libc::SO_ACCEPTCONN,
                (&mut accepting as *mut libc::c_int).cast(),
                &mut len,
            )
        };
        ensure!(rc == 0 && accepting == 1, "inherited descriptor is not a listener");
        // SAFETY: validated unique, owned inherited descriptor, consumed only once.
        super::listener_handover::add_received(&mut listeners, &kind, unsafe {
            OwnedFd::from_raw_fd(fd)
        });
    }
    ensure!(
        listeners.unix.as_ref().is_some_and(|l| super::listener_handover::serves_path(
            l,
            &crate::config::socket_path()
        )),
        "exec handoff has no matching unix listener"
    );
    let _ = INSTALLED.set(manifest.installed);
    let _ = IMAGE.set(manifest.image);
    NEEDS_KEY.store(manifest.needs_key, std::sync::atomic::Ordering::SeqCst);
    let _ = RECEIPT.set(manifest.id);
    Ok(Some(Inherited { lock, listeners }))
}

pub(crate) fn add_receipt(status: &mut serde_json::Value) {
    if NEEDS_KEY.load(std::sync::atomic::Ordering::SeqCst)
        && status.get("personKey").and_then(serde_json::Value::as_bool) != Some(true)
    {
        return; // A keyed image is not confirmed until the existing app/provisioner reenrolls it.
    }
    if let Some(id) = RECEIPT.get() {
        status["execImage"] = serde_json::json!(IMAGE.get());
        status["lastExecUpdate"] = serde_json::Value::String(id.clone());
    }
}

pub(crate) fn pending() -> bool {
    PENDING.lock().unwrap_or_else(std::sync::PoisonError::into_inner).is_some()
}

/// Called only while the update drain owns admission. Readiness failure leaves it serving.
pub(crate) async fn prepare(hub: &crate::hub::Hub) -> Result<serde_json::Value> {
    require_unkeyed(hub)?;
    let program = super::exe_swap::installed_path().context("no installed daemon path")?;
    let executable = std::fs::File::open(&program)?;
    let before = Image::of(&executable, String::new())?;
    let check = program.clone();
    let prefix = super::daemon_prefix();
    let image = tokio::task::spawn_blocking(move || -> Result<Image> {
        use std::io::Read;
        let mut child = cmux_process::Command::new(&check)
            .args(prefix)
            .arg(CHECK_ARG)
            .stdin(cmux_process::Stdio::null())
            .stdout(cmux_process::Stdio::piped())
            .stderr(cmux_process::Stdio::null())
            .spawn()?;
        let status = child
            .wait_timeout(super::exe_swap::READY_WITHIN)?
            .context("updated executable did not answer exec protocol preflight")?;
        ensure!(status.success(), "updated executable does not support exec handoff: {status}");
        let stdout = child.stdout.take().context("missing exec preflight output")?;
        // Never wait for descendants holding stdout after the checked child exited.
        let fd = stdout.as_raw_fd();
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
        ensure!(
            flags >= 0 && unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } == 0,
            "cannot bound exec preflight output"
        );
        let mut bytes = Vec::new();
        stdout.take(4097).read_to_end(&mut bytes)?;
        ensure!(bytes.len() <= 4096, "exec preflight output exceeds limit");
        let answer: serde_json::Value = serde_json::from_slice(&bytes)?;
        ensure!(
            answer.get("execProtocol").and_then(serde_json::Value::as_u64)
                == Some(u64::from(PROTOCOL)),
            "updated executable has incompatible exec protocol"
        );
        let image: Image = serde_json::from_value(answer["image"].clone())?;
        let expected = Image { build: image.build.clone(), ..before };
        ensure!(image == expected, "installed executable changed during preflight");
        Ok(image)
    })
    .await??;
    // Enrollment can complete while the candidate answers its preflight.
    require_unkeyed(hub)?;
    ensure!(
        Image::of(&executable, image.build.clone())? == image,
        "checked executable changed during preflight"
    );
    // Normalize multicall invocations: argv0 may have been the acpmux symlink, whereas
    // the pinned executable resolves to cmux-tui and needs its explicit acp prefix.
    let engine_args = crate::cli::entry::original_args()
        .map(<[String]>::to_vec)
        .unwrap_or_else(|| std::env::args().skip(1).collect());
    let args = exec_args(
        super::daemon_prefix()
            .into_iter()
            .map(|a| a.to_string_lossy().into_owned())
            .chain(engine_args),
    );
    let listeners = super::listener_handover::offered_listeners();
    ensure!(
        listeners.iter().any(|(kind, _)| *kind == b"unix"),
        "cannot preserve daemon unix listener"
    );
    let id = super::random_token()?;
    let mut pending = PENDING.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    ensure!(pending.is_none(), "an exec update is already pending");
    let receipt = serde_json::json!({"updateId": id, "execImage": image});
    *pending = Some(Plan {
        program,
        executable,
        image,
        needs_key: hub.person.has_key(),
        args,
        id,
        listeners,
    });
    super::listener_handover::mark_kept();
    Ok(receipt)
}

fn require_unkeyed(hub: &crate::hub::Hub) -> Result<()> {
    ensure!(
        !hub.person.has_key(),
        "person-key daemon requires the existing keyed handoff; exec update deferred before shutdown"
    );
    Ok(())
}

fn exec_args(args: impl IntoIterator<Item = String>) -> Vec<String> {
    let mut args = args.into_iter();
    let mut out = Vec::new();
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--ready-fd" | "--person-key-fd" => {
                args.next();
            }
            "--take-over" => {}
            arg if arg.starts_with("--ready-fd=") || arg.starts_with("--person-key-fd=") => {}
            _ => out.push(arg),
        }
    }
    out
}

/// After all writes end, while still owning the original lock. Success never returns.
pub(super) fn replace(lock: &super::lock::DaemonLock) -> Result<()> {
    let plan = PENDING
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .take()
        .ok_or_else(|| anyhow!("exec update plan disappeared"))?;
    let manifest = Manifest {
        pid: std::process::id(),
        id: plan.id,
        installed: plan.program.clone(),
        image: plan.image.clone(),
        needs_key: plan.needs_key,
        lock: lock.as_fd().as_raw_fd(),
        listeners: plan
            .listeners
            .iter()
            .map(|(kind, fd)| (kind.to_vec(), fd.as_raw_fd()))
            .collect(),
    };
    let mut env: Vec<(OsString, OsString)> = std::env::vars_os()
        .filter(|(key, _)| key != ENV && key != "ACPMUX_HANDOVER_UPDATE_OWNER")
        .collect();
    env.push((ENV.into(), serde_json::to_string(&manifest)?.into()));
    let mut fds = vec![lock.as_fd()];
    fds.extend(plan.listeners.iter().map(|(_, fd)| fd.as_fd()));
    ensure!(
        Image::of(&plan.executable, plan.image.build.clone())? == plan.image,
        "checked update executable changed before exec"
    );
    #[cfg(target_os = "linux")]
    let exec_path = PathBuf::from(format!("/proc/self/fd/{}", plan.executable.as_raw_fd()));
    #[cfg(not(target_os = "linux"))]
    let exec_path = {
        ensure!(
            Image::of(&std::fs::File::open(&plan.program)?, plan.image.build.clone())?
                == plan.image,
            "installed executable changed before exec"
        );
        plan.program.clone()
    };
    Err(cmux_process::exec_replace_inheriting(&exec_path, &plan.args, env, &fds))
        .context("exec updated daemon")
}

#[cfg(test)]
mod tests {
    #[tokio::test]
    async fn keyed_daemon_defers_before_exec_preflight_or_shutdown() {
        use crate::config::{Config, StoreMode};
        let mut config = Config::default();
        config.store.mode = StoreMode::Memory;
        let store =
            crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
        let hub = crate::hub::Hub::new(config, store);
        let key = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        hub.person.install_spawn_key(key).unwrap();
        let error = super::prepare(&hub).await.unwrap_err();
        assert!(error.to_string().contains("person-key daemon"), "{error:#}");
        assert!(hub.person.has_key());
        assert!(!hub.shutting_down());
        assert!(!super::pending());
    }

    #[test]
    fn exec_drops_consumed_start_descriptors_and_takeover() {
        let args = [
            "daemon",
            "run",
            "--ready-fd",
            "9",
            "--person-key-fd=10",
            "--take-over",
            "--no-idle-exit",
        ];
        assert_eq!(super::exec_args(args.map(str::to_owned)), ["daemon", "run", "--no-idle-exit"]);
    }
}
