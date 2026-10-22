//! Which addresses a phone's streamed browser tab may load (PROTOCOL.md
//! `browser`, SECURITY.md `browser`).
//!
//! - **A page the Mac shows.** An address one of the Mac's own browser tabs
//!   shows (the daemon's `list-workspaces`), or the one the tab was opened
//!   at after that check, always loads: the phone views what is already on
//!   the Mac's screen. That covers `file:` pages anywhere and the browser's
//!   own pages, but never `javascript:` or an app scheme (no browser tab
//!   shows those as a page).
//! - **An address the phone asks for** (the address bar, a link inside the
//!   page): `http(s)`, `about:blank`, `data:`, `blob:`, `view-source:` of
//!   `http(s)`, and `file:` inside the folders the Mac shares with the phone
//!   (the `file` service's roots: Chat Folders and workspace folders, never
//!   home, its parents or `~/.ssh`, `~/Library` and the other credential
//!   trees). Everything else is refused with a sentence the phone shows.

use std::path::{Path, PathBuf};

use futures_util::future::BoxFuture;

/// The longest address a phone may load.
pub const MAX_URL_BYTES: usize = 8192;

/// What an address is, before any check against the Mac's state.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Target {
    /// `http(s)`, `about:blank`, `data:`, `blob:`, `view-source:` of a web page.
    Web,
    /// A `file:` URL: its path, percent-decoded.
    File(PathBuf),
    /// The browser's own pages (`chrome:`, `devtools:`, `about:` other than
    /// blank, `view-source:` of anything but the web): only when the Mac shows one.
    BrowserPage,
    /// Never loads from a phone.
    Refused(Blocked),
}

/// Why an address does not load.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Blocked {
    /// `javascript:`.
    Script,
    /// A browser page (`chrome:`, `devtools:`, ...) the Mac does not show.
    BrowserPage,
    /// A scheme another Mac app handles (`zoommtg:`, `vscode:`, `x-apple...`).
    AppScheme,
    /// A `file:` outside every folder the Mac shares (or no folder is shared).
    FileElsewhere,
    /// A `file:` inside a shared folder that does not exist.
    FileMissing,
    /// Not an address, or longer than [`MAX_URL_BYTES`].
    Malformed,
}

impl Blocked {
    /// The sentence the phone shows.
    pub fn message(self) -> &'static str {
        match self {
            Self::Script => "Scripts can't run from your iPhone's address bar.",
            Self::BrowserPage => "Browser settings and internal pages can't open from your iPhone.",
            Self::AppScheme => "Links that open other apps on your Mac can't open from your iPhone.",
            Self::FileElsewhere => "This file isn't in a folder this Mac shares with your iPhone.",
            Self::FileMissing => "There's no such file in the folders this Mac shares.",
            Self::Malformed => "This address can't be opened.",
        }
    }

    /// The machine-readable reason in `rb.navigate.refused` (`code`), which the
    /// phone shows in its own words.
    pub fn wire_code(self) -> &'static str {
        match self {
            Self::Script => "script",
            Self::BrowserPage => "browser_page",
            Self::AppScheme => "app_scheme",
            Self::FileElsewhere => "file_not_shared",
            Self::FileMissing => "file_missing",
            Self::Malformed => "malformed",
        }
    }

    /// The refusal code of a `browser` open (`forbidden`; `not_found` for a missing file).
    pub fn code(self) -> &'static str {
        match self {
            Self::FileMissing => "not_found",
            Self::Malformed => "bad_request",
            _ => "forbidden",
        }
    }
}

/// The Mac's state the checks read, from one daemon answer.
#[derive(Debug, Clone, Default)]
pub struct MacView {
    /// The folders a phone may read below (`services::shared_file_roots`).
    pub roots: Vec<PathBuf>,
    /// The address of every browser tab the daemon lists.
    pub browser_urls: Vec<String>,
}

/// Where the checks read the Mac's state (one `list-workspaces` per call).
pub trait MacPages: Send + Sync {
    fn view(&self) -> BoxFuture<'_, MacView>;
}

/// Why an address may load.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Allowed {
    /// A web, data, blob or blank address: no Mac state needed.
    Web,
    /// A file inside a shared folder, resolved (symlinks followed): load this
    /// path, not the address as written, so a symlink swapped in after the
    /// check cannot redirect the load.
    SharedFile(PathBuf),
    /// One of the Mac's own browser tabs shows it (or this tab opened at it).
    MacShows,
}

/// The resolved `file:` URL to load for `url` (a shared file at `resolved`):
/// its canonical path, with the `?query` and `#fragment` the address had.
pub fn resolved_file_url(url: &str, resolved: &Path) -> String {
    let rest = url.trim().get("file:".len()..).unwrap_or_default();
    let suffix = rest.find(['?', '#']).map_or("", |i| &rest[i..]);
    format!("{}{suffix}", file_url(resolved))
}

/// `path` as a `file:` URL, percent-encoded.
pub fn file_url(path: &Path) -> String {
    use std::os::unix::ffi::OsStrExt;
    let mut out = String::from("file://");
    for &b in path.as_os_str().as_bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'/' | b'-' | b'_' | b'.' | b'~') {
            out.push(char::from(b));
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// The scheme of `url`, lowercased, when it has one (RFC 3986 `scheme ":"`).
fn scheme(url: &str) -> Option<String> {
    let (scheme, _) = url.split_once(':')?;
    let mut chars = scheme.chars();
    let first = chars.next()?;
    (first.is_ascii_alphabetic() && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.')))
        .then(|| scheme.to_ascii_lowercase())
}

fn is_web(lower: &str) -> bool {
    lower.starts_with("https://") || lower.starts_with("http://")
}

/// What `url` is (no filesystem or daemon access).
pub fn classify(url: &str) -> Target {
    let url = url.trim();
    if url.is_empty() || url.len() > MAX_URL_BYTES || url.chars().any(char::is_control) {
        return Target::Refused(Blocked::Malformed);
    }
    let Some(scheme) = scheme(url) else { return Target::Refused(Blocked::Malformed) };
    let lower = url.to_ascii_lowercase();
    match scheme.as_str() {
        "http" | "https" if is_web(&lower) => Target::Web,
        "http" | "https" => Target::Refused(Blocked::Malformed),
        "about"
            if lower == "about:blank"
                || lower.starts_with("about:blank#")
                || lower.starts_with("about:blank?") =>
        {
            Target::Web
        }
        "about" => Target::BrowserPage,
        "data" | "blob" => Target::Web,
        "view-source" if is_web(&lower["view-source:".len()..]) => Target::Web,
        "view-source" => Target::BrowserPage,
        "file" => file_path(url).map_or(Target::Refused(Blocked::Malformed), Target::File),
        "javascript" => Target::Refused(Blocked::Script),
        "chrome" | "chrome-extension" | "chrome-untrusted" | "chrome-search" | "chrome-native"
        | "devtools" | "filesystem" => Target::BrowserPage,
        _ => Target::Refused(Blocked::AppScheme),
    }
}

/// The path of a `file:` URL: `file:///p`, `file://localhost/p` or `file:/p`,
/// percent-decoded, without its query or fragment. None for another host, a
/// relative path, a NUL or a bad escape.
pub fn file_path(url: &str) -> Option<PathBuf> {
    let rest = url.get("file:".len()..)?;
    let rest = rest.split(['?', '#']).next().unwrap_or_default();
    let path = if let Some(after) = rest.strip_prefix("//") {
        let (host, path) = after.find('/').map_or((after, ""), |i| (&after[..i], &after[i..]));
        if !(host.is_empty() || host.eq_ignore_ascii_case("localhost")) {
            return None;
        }
        path
    } else {
        rest
    };
    if !path.starts_with('/') {
        return None;
    }
    let bytes = percent_decode(path)?;
    if bytes.contains(&0) {
        return None;
    }
    use std::os::unix::ffi::OsStrExt;
    Some(PathBuf::from(std::ffi::OsStr::from_bytes(&bytes)))
}

fn percent_decode(text: &str) -> Option<Vec<u8>> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = text.get(i + 1..i + 3)?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    Some(out)
}

/// Whether two addresses name the same page: the same file (resolved), or
/// the same text.
pub fn same_page(a: &str, b: &str) -> bool {
    let (a, b) = (a.trim(), b.trim());
    if a == b {
        return true;
    }
    match (classify(a), classify(b)) {
        (Target::File(x), Target::File(y)) => {
            x == y
                || matches!((std::fs::canonicalize(&x), std::fs::canonicalize(&y)), (Ok(x), Ok(y)) if x == y)
        }
        _ => false,
    }
}

/// Where `path` resolves inside `roots` (symlinks may not escape), or why not.
pub fn inside_roots(roots: &[PathBuf], path: &Path) -> Result<PathBuf, Blocked> {
    let roots: Vec<PathBuf> = roots.iter().filter_map(|r| std::fs::canonicalize(r).ok()).collect();
    match std::fs::canonicalize(path) {
        Ok(resolved) if roots.iter().any(|root| resolved.starts_with(root)) => Ok(resolved),
        Ok(_) => Err(Blocked::FileElsewhere),
        // Missing: say so only when the path is inside a shared folder as
        // written, so the answer tells nothing about the rest of the disk.
        Err(_) if roots.iter().any(|root| path.starts_with(root)) => Err(Blocked::FileMissing),
        Err(_) => Err(Blocked::FileElsewhere),
    }
}

/// Whether the Mac's state is needed to decide `url` (a file or a browser page).
pub fn needs_view(url: &str) -> bool {
    matches!(classify(url), Target::File(_) | Target::BrowserPage)
}

/// Whether `url` may load, given the Mac's state. `approved`: addresses this
/// tab was allowed to open because the Mac showed them.
pub fn decide(url: &str, view: &MacView, approved: &[String]) -> Result<Allowed, Blocked> {
    let mac_shows = || approved.iter().chain(&view.browser_urls).any(|shown| same_page(shown, url));
    match classify(url) {
        Target::Web => Ok(Allowed::Web),
        Target::Refused(blocked) => Err(blocked),
        Target::File(path) => match inside_roots(&view.roots, &path) {
            Ok(resolved) => Ok(Allowed::SharedFile(resolved)),
            Err(_) if mac_shows() => Ok(Allowed::MacShows),
            Err(blocked) => Err(blocked),
        },
        Target::BrowserPage if mac_shows() => Ok(Allowed::MacShows),
        Target::BrowserPage => Err(Blocked::BrowserPage),
    }
}

/// [`decide`], reading the Mac's state only when the address needs it.
pub async fn check(url: &str, mac: &dyn MacPages, approved: &[String]) -> Result<Allowed, Blocked> {
    let view = if needs_view(url) { mac.view().await } else { MacView::default() };
    decide(url, &view, approved)
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Mac {
        roots: Vec<PathBuf>,
        urls: Vec<String>,
    }

    impl MacPages for Mac {
        fn view(&self) -> BoxFuture<'_, MacView> {
            Box::pin(async move { MacView { roots: self.roots.clone(), browser_urls: self.urls.clone() } })
        }
    }

    async fn ok(url: &str, mac: &Mac, approved: &[String]) -> Result<(), Blocked> {
        check(url, mac, approved).await.map(|_| ())
    }

    #[test]
    fn schemes() {
        for web in [
            "https://example.com",
            "HTTP://example.com/a?b#c",
            "about:blank",
            " about:blank ",
            "about:blank#top",
            "data:text/html,<h1>hi</h1>",
            "blob:https://example.com/0f6e",
            "view-source:https://example.com",
        ] {
            assert_eq!(classify(web), Target::Web, "{web}");
        }
        assert_eq!(classify("javascript:alert(1)"), Target::Refused(Blocked::Script));
        assert_eq!(classify(" JavaScript:alert(1)"), Target::Refused(Blocked::Script));
        for page in [
            "chrome://settings",
            "chrome-extension://abc/x.html",
            "devtools://devtools/bundled/inspector.html",
            "about:config",
            "view-source:file:///etc/passwd",
            "filesystem:https://example.com/temporary/x",
        ] {
            assert_eq!(classify(page), Target::BrowserPage, "{page}");
        }
        for app in ["zoommtg://zoom.us/join", "vscode://file/x", "x-apple.systempreferences:", "mailto:a@b.c"]
        {
            assert_eq!(classify(app), Target::Refused(Blocked::AppScheme), "{app}");
        }
        for bad in ["", "example.com", "http:example.com", "https:/x", "a b:c", "https://x\n.com"] {
            assert_eq!(classify(bad), Target::Refused(Blocked::Malformed), "{bad:?}");
        }
        assert_eq!(
            classify(&format!("https://{}", "a".repeat(MAX_URL_BYTES))),
            Target::Refused(Blocked::Malformed)
        );
    }

    #[test]
    fn file_urls() {
        assert_eq!(file_path("file:///Users/me/a%20b.html"), Some(PathBuf::from("/Users/me/a b.html")));
        assert_eq!(file_path("file://localhost/tmp/x?q=1#top"), Some(PathBuf::from("/tmp/x")));
        assert!(file_path("FILE:///tmp/x").is_some());
        assert_eq!(file_path("file:/tmp/x"), Some(PathBuf::from("/tmp/x")));
        assert_eq!(file_path("file://server/share/x"), None);
        assert_eq!(file_path("file://"), None);
        assert_eq!(file_path("file:relative"), None);
        assert_eq!(file_path("file:///tmp/%00x"), None);
        assert_eq!(file_path("file:///tmp/%zz"), None);
        assert_eq!(file_path("file:///tmp/%2"), None);
    }

    #[tokio::test]
    async fn files_load_inside_the_shared_folders_only() {
        let shared = tempfile::tempdir().unwrap();
        let elsewhere = tempfile::tempdir().unwrap();
        std::fs::write(shared.path().join("page one.html"), "<p>in</p>").unwrap();
        std::fs::write(elsewhere.path().join("secret.html"), "<p>out</p>").unwrap();
        std::os::unix::fs::symlink(elsewhere.path().join("secret.html"), shared.path().join("link.html"))
            .unwrap();
        let mac = Mac { roots: vec![shared.path().to_path_buf()], urls: vec![] };
        let inside = file_url(&shared.path().join("page one.html"));
        assert_eq!(ok(&inside, &mac, &[]).await, Ok(()));
        // A folder of a shared folder lists.
        assert_eq!(ok(&file_url(shared.path()), &mac, &[]).await, Ok(()));
        let outside = file_url(&elsewhere.path().join("secret.html"));
        assert_eq!(ok(&outside, &mac, &[]).await, Err(Blocked::FileElsewhere));
        // A symlink out of the folder, and `..`, do not escape it.
        assert_eq!(
            ok(&file_url(&shared.path().join("link.html")), &mac, &[]).await,
            Err(Blocked::FileElsewhere)
        );
        let dotdot = format!(
            "{}/../{}/secret.html",
            file_url(shared.path()),
            elsewhere.path().file_name().unwrap().to_str().unwrap()
        );
        assert_eq!(ok(&dotdot, &mac, &[]).await, Err(Blocked::FileElsewhere));
        // Missing inside: said so; missing elsewhere: the same answer as any outside file.
        assert_eq!(
            ok(&file_url(&shared.path().join("gone.html")), &mac, &[]).await,
            Err(Blocked::FileMissing)
        );
        assert_eq!(ok("file:///no/such/file.html", &mac, &[]).await, Err(Blocked::FileElsewhere));
        // No shared folder: nothing loads.
        let none = Mac { roots: vec![], urls: vec![] };
        assert_eq!(ok(&inside, &none, &[]).await, Err(Blocked::FileElsewhere));
    }

    #[tokio::test]
    async fn a_shared_file_loads_at_its_resolved_path() {
        let shared = tempfile::tempdir().unwrap();
        std::fs::create_dir(shared.path().join("sub")).unwrap();
        std::fs::write(shared.path().join("sub/a b.html"), "x").unwrap();
        let mac = Mac { roots: vec![shared.path().to_path_buf()], urls: vec![] };
        let written = format!("{}/sub/../sub/a%20b.html", file_url(shared.path()));
        let resolved = std::fs::canonicalize(shared.path().join("sub/a b.html")).unwrap();
        assert_eq!(check(&written, &mac, &[]).await, Ok(Allowed::SharedFile(resolved.clone())));
        assert_eq!(file_path(&file_url(&resolved)), Some(resolved));
        assert_eq!(
            resolved_file_url("file:///x/a.html?q=1#install", Path::new("/r/a b.html")),
            "file:///r/a%20b.html?q=1#install"
        );
        assert_eq!(resolved_file_url("file:///x/a.html", Path::new("/r/a.html")), "file:///r/a.html");
        // Web addresses never ask the Mac.
        assert!(!needs_view("https://example.com") && !needs_view("data:,x") && needs_view("file:///x"));
    }

    #[tokio::test]
    async fn a_page_the_mac_shows_always_loads() {
        let elsewhere = tempfile::tempdir().unwrap();
        let page = elsewhere.path().join("iphone link sequence.html");
        std::fs::write(&page, "<p>mac</p>").unwrap();
        // The daemon spells it percent-encoded; the phone may spell it either way.
        let shown = file_url(&page);
        let mac = Mac { roots: vec![], urls: vec![shown.clone(), "chrome://version/".into()] };
        assert_eq!(ok(&shown, &mac, &[]).await, Ok(()));
        assert_eq!(
            ok(&format!("file://localhost{}", page.display()).replace(' ', "%20"), &mac, &[]).await,
            Ok(())
        );
        assert_eq!(ok("chrome://version/", &mac, &[]).await, Ok(()));
        // Another file in the same folder, or another browser page, does not.
        assert_eq!(
            ok(&file_url(&elsewhere.path().join("other.html")), &mac, &[]).await,
            Err(Blocked::FileElsewhere)
        );
        assert_eq!(ok("chrome://settings", &mac, &[]).await, Err(Blocked::BrowserPage));
        // Approved at open: still loads after the Mac's tab moved on.
        let moved = Mac { roots: vec![], urls: vec![] };
        assert_eq!(ok(&shown, &moved, std::slice::from_ref(&shown)).await, Ok(()));
        // A script or an app scheme never loads, even if the daemon listed it.
        let odd = Mac { roots: vec![], urls: vec!["javascript:alert(1)".into(), "zoommtg://x".into()] };
        assert_eq!(ok("javascript:alert(1)", &odd, &[]).await, Err(Blocked::Script));
        assert_eq!(ok("zoommtg://x", &odd, &[]).await, Err(Blocked::AppScheme));
    }

    #[test]
    fn messages_are_sentences() {
        assert_eq!(
            Blocked::FileElsewhere.message(),
            "This file isn't in a folder this Mac shares with your iPhone."
        );
        for b in [
            Blocked::Script,
            Blocked::BrowserPage,
            Blocked::AppScheme,
            Blocked::FileElsewhere,
            Blocked::FileMissing,
            Blocked::Malformed,
        ] {
            assert!(b.message().ends_with('.') && !b.message().contains("http"), "{b:?}");
        }
    }
}
