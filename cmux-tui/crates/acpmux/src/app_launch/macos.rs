//! macOS: apps are bundles, opened through LaunchServices (`/usr/bin/open`) in the person's GUI
//! session (`daemon/login_session.rs`'s `in_gui_session`).

use super::{App, LaunchRequest, Refusal, Running};
use crate::daemon::login_placement::GuiSession;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// LaunchServices' list of the apps it runs.
const LSAPPINFO: &str = "/usr/bin/lsappinfo";
/// How long `lsappinfo list` may take.
const LSAPPINFO_BUDGET: Duration = Duration::from_secs(3);

/// The folders apps are found in, in the order a name is looked up.
fn folders() -> Vec<PathBuf> {
    let mut folders: Vec<PathBuf> = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
    ]
    .iter()
    .map(PathBuf::from)
    .collect();
    if let Some(home) = dirs::home_dir() {
        folders.push(home.join("Applications"));
    }
    folders
}

/// Whether someone is logged in at the screen, and it is this daemon's user.
pub(super) fn session() -> Result<(), Refusal> {
    crate::daemon::login_session::in_gui_session(Vec::new()).map(|_| ()).map_err(refusal)
}

fn refusal(why: GuiSession) -> Refusal {
    match why {
        GuiSession::Nobody => Refusal::NoSession("the login window is up".into()),
        GuiSession::OtherUser(uid) => Refusal::OtherUser(user_name(uid)),
    }
}

fn user_name(uid: u32) -> String {
    // SAFETY: getpwuid returns a pointer into static storage or null; read at once.
    unsafe {
        let pw = libc::getpwuid(uid);
        if pw.is_null() || (*pw).pw_name.is_null() {
            return format!("uid {uid}");
        }
        std::ffi::CStr::from_ptr((*pw).pw_name).to_string_lossy().into_owned()
    }
}

/// Every bundle in [`folders`], and one folder deep in /Applications (`/Applications/Foo/Foo.app`).
pub(super) fn apps() -> Vec<App> {
    let mut apps = Vec::new();
    for folder in folders() {
        let Ok(entries) = std::fs::read_dir(&folder) else { continue };
        let mut paths: Vec<PathBuf> = entries.flatten().map(|e| e.path()).collect();
        paths.sort();
        for path in paths {
            if apps.len() >= super::MAX_APPS {
                return apps;
            }
            if path.extension().is_some_and(|e| e == "app") {
                apps.extend(bundle(&path));
            } else if folder == Path::new("/Applications") && path.is_dir() {
                let Ok(inner) = std::fs::read_dir(&path) else { continue };
                let mut inner: Vec<PathBuf> = inner.flatten().map(|e| e.path()).collect();
                inner.sort();
                apps.extend(
                    inner
                        .iter()
                        .filter(|p| p.extension().is_some_and(|e| e == "app"))
                        .filter_map(|p| bundle(p)),
                );
            }
        }
    }
    apps
}

/// The bundle at `path`, from its `Info.plist`.
fn bundle(path: &Path) -> Option<App> {
    let info = plist::Value::from_file(path.join("Contents/Info.plist")).ok();
    let info = info.as_ref().and_then(plist::Value::as_dictionary);
    let key =
        |k: &str| info.and_then(|d| d.get(k)).and_then(plist::Value::as_string).map(str::to_owned);
    let stem = path.file_stem()?.to_string_lossy().into_owned();
    Some(App {
        // The bundle's file name is what the Finder and `open -a` show; a display name only
        // when it says more than a short `CFBundleName`.
        name: key("CFBundleDisplayName").filter(|n| n.len() > stem.len()).unwrap_or(stem),
        id: key("CFBundleIdentifier"),
        exe: Some(path.join("Contents/MacOS")),
        path: path.to_path_buf(),
    })
}

/// The apps LaunchServices says run in the person's GUI session (`lsappinfo list`, asked in that
/// session): its registry of the apps it launched, not a scan of the machine's processes.
pub(super) fn running() -> Vec<Running> {
    let argv = vec![LSAPPINFO.to_owned(), "list".to_owned()];
    let Ok(argv) = crate::daemon::login_session::in_gui_session(argv) else { return Vec::new() };
    let argv: Vec<&str> = argv.iter().map(String::as_str).collect();
    super::output_bounded(&argv, LSAPPINFO_BUDGET)
        .map(|out| super::lsappinfo_running(&out))
        .unwrap_or_default()
}

pub(super) fn open(
    app: &App,
    request: &LaunchRequest,
    deadline: Instant,
) -> Result<Option<u32>, Refusal> {
    let argv = super::mac_open_argv(app, request);
    let argv = crate::daemon::login_session::in_gui_session(argv).map_err(refusal)?;
    let status = super::run_bounded(&argv, &[], deadline).map_err(Refusal::Failed)?;
    if !status.success() {
        return Err(Refusal::Failed(format!("LaunchServices refused it ({status})")));
    }
    // LaunchServices started it; its pid comes from its registry (`running`).
    Ok(None)
}
