//! Which cmux-tui daemon socket the Computer Use bridge (`acpmux computer-use-mcp`) and the relay
//! ask for the worker.
//!
//! An agent in a cmux terminal or chat gets the socket in `CMUX_TUI_SOCKET`. An agent started
//! anywhere else (a Claude Code in another terminal, a launchd job, the duress suite) got the
//! `main` session's socket, which no app runs, so every call failed with "the cmux daemon is not
//! reachable: No such file or directory (os error 2)" while the app's daemon was up. Now, without
//! `CMUX_TUI_SOCKET`, the bridge asks the daemon of the app that `CMUX_BUNDLE_ID` / `CMUX_TAG`
//! name, else of the app bundle this `acpmux` ships in, at the app's session socket
//! ([`BuildIdentity::app_session`], or the old shared `cmux-app` once that build adopted it) in
//! the folder the app starts its daemon in (on macOS the per-user Darwin temp folder, whatever
//! this process's `TMPDIR` is). `main` is the last resort. The first candidate whose socket exists
//! wins; when none does, the error names every path it looked at.

use std::path::{Path, PathBuf};

use cmux_agent_pane_policy::build_identity::BuildIdentity;

/// One place the daemon may listen, and what named it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Candidate {
    pub path: PathBuf,
    pub source: &'static str,
}

/// What the lookup reads, so tests give it fakes.
pub struct Inputs<'a> {
    pub env: &'a dyn Fn(&str) -> Option<String>,
    /// This executable (canonical): the app bundle around it names the build.
    pub exe: Option<&'a Path>,
    /// The user's home, for the legacy-session marker.
    pub home: Option<&'a Path>,
    /// The folder the app starts its daemon with as `TMPDIR` (macOS: the Darwin user temp
    /// folder); None where the app uses this process's own runtime folder.
    pub app_base: Option<&'a Path>,
    /// `session`'s socket in this process's own runtime folder.
    pub own_socket: &'a dyn Fn(&str) -> PathBuf,
}

/// Every place to look, best first.
pub fn candidates(inputs: &Inputs<'_>) -> Vec<Candidate> {
    let var = |key: &str| (inputs.env)(key).filter(|v| !v.trim().is_empty());
    let mut out: Vec<Candidate> = Vec::new();
    let mut push = |path: PathBuf, source: &'static str| {
        if !out.iter().any(|c| c.path == path) {
            out.push(Candidate { path, source });
        }
    };
    // The app's terminals and chats name it: that always wins, alone.
    if let Some(path) = var("CMUX_TUI_SOCKET").or_else(|| var("CMUX_MUX_SOCKET")) {
        push(PathBuf::from(path), "CMUX_TUI_SOCKET");
        return out;
    }
    let env_build =
        BuildIdentity::new(var("CMUX_BUNDLE_ID").as_deref(), var("CMUX_TAG").as_deref());
    let builds = [
        (Some(env_build), "CMUX_BUNDLE_ID"),
        (inputs.exe.and_then(bundle_build), "the app bundle around acpmux"),
    ];
    for (build, source) in builds {
        let Some(session) = build.as_ref().and_then(|b| app_session(b, inputs.home)) else {
            continue;
        };
        if let Some(base) = inputs.app_base {
            push(socket_in_base(&session, base, inputs.own_socket), source);
        }
        push((inputs.own_socket)(&session), source);
    }
    push((inputs.own_socket)("main"), "the main session");
    out
}

/// The first candidate whose socket exists, else the first one.
pub fn pick(candidates: &[Candidate]) -> Option<&Candidate> {
    candidates.iter().find(|c| c.path.exists()).or_else(|| candidates.first())
}

/// The daemon session `build`'s app runs: its own, or the old shared `cmux-app` once it adopted
/// it (its legacy marker). None outside an app.
pub fn app_session(build: &BuildIdentity, home: Option<&Path>) -> Option<String> {
    let session = build.app_session()?;
    let adopted = home.is_some_and(|home| {
        [build.legacy_session_marker(home), build.legacy_session_marker_before_move(home)]
            .into_iter()
            .flatten()
            .any(|marker| marker.is_file())
    });
    Some(if adopted { "cmux-app".to_owned() } else { session })
}

/// `session`'s socket when its owner runs with `TMPDIR=base` and no `XDG_RUNTIME_DIR` (how the
/// app starts its daemon; cmux-tui-core `try_default_socket_path_in_base`). A path too long for
/// a Unix socket takes the runtime folder's own short fallback.
fn socket_in_base(session: &str, base: &Path, own_socket: &dyn Fn(&str) -> PathBuf) -> PathBuf {
    let preferred =
        cmux_tui_platform::platform::runtime_dir_for_base(base).join(format!("{session}.sock"));
    if cmux_unix_socket::fits(&preferred) { preferred } else { own_socket(session) }
}

/// The build of the cmux app bundle around `exe` (its `Info.plist` bundle id and shipped
/// `CMUX_TAG`, or a `cmux DEV <tag>.app` name's tag). None outside a cmux app.
pub fn bundle_build(exe: &Path) -> Option<BuildIdentity> {
    let bundle = exe
        .ancestors()
        .find(|path| path.extension().is_some_and(|extension| extension == "app"))
        .filter(|bundle| exe.starts_with(bundle.join("Contents")))?;
    let info = plist::Value::from_file(bundle.join("Contents/Info.plist")).ok()?;
    let dictionary = info.as_dictionary()?;
    let bundle_id = dictionary.get("CFBundleIdentifier")?.as_string()?;
    if !bundle_id.starts_with("com.cmuxterm.app") {
        return None;
    }
    let tag = dictionary
        .get("LSEnvironment")
        .and_then(plist::Value::as_dictionary)
        .and_then(|environment| environment.get("CMUX_TAG"))
        .and_then(plist::Value::as_string)
        .map(str::to_owned)
        .or_else(|| bundle.file_stem()?.to_str()?.strip_prefix("cmux DEV ").map(str::to_owned));
    Some(BuildIdentity::new(Some(bundle_id), tag.as_deref()))
}

/// The candidates for this process.
pub fn from_process() -> Vec<Candidate> {
    let env = |key: &str| std::env::var(key).ok();
    let exe = std::env::current_exe().ok().map(|exe| exe.canonicalize().unwrap_or(exe));
    let home = std::env::var_os("HOME").map(PathBuf::from);
    let app_base = app_base();
    candidates(&Inputs {
        env: &env,
        exe: exe.as_deref(),
        home: home.as_deref(),
        app_base: app_base.as_deref(),
        own_socket: &|session| cmux::raw::default_socket_path(session),
    })
}

/// macOS: `confstr(_CS_DARWIN_USER_TEMP_DIR)`, the `TMPDIR` the app starts its daemon with
/// (`DaemonLauncher`, the app's `userTemporaryDirectory`).
#[cfg(target_os = "macos")]
fn app_base() -> Option<PathBuf> {
    use std::os::unix::ffi::OsStringExt;
    // SAFETY: a null buffer of length 0 asks for the required length.
    let length = unsafe { libc::confstr(libc::_CS_DARWIN_USER_TEMP_DIR, std::ptr::null_mut(), 0) };
    if length == 0 {
        return None;
    }
    let mut buffer = vec![0u8; length];
    // SAFETY: buffer holds `length` bytes, the size confstr reported.
    let written = unsafe {
        libc::confstr(libc::_CS_DARWIN_USER_TEMP_DIR, buffer.as_mut_ptr().cast(), length)
    };
    if written == 0 {
        return None;
    }
    let end = buffer.iter().position(|byte| *byte == 0).unwrap_or(buffer.len());
    buffer.truncate(end);
    (!buffer.is_empty()).then(|| PathBuf::from(std::ffi::OsString::from_vec(buffer)))
}

#[cfg(not(target_os = "macos"))]
fn app_base() -> Option<PathBuf> {
    None
}

#[cfg(all(test, unix))]
#[path = "daemon_socket_tests.rs"]
mod tests;
