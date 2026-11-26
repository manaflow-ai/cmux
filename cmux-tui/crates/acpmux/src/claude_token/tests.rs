use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use super::pty::{find_url, strip_ansi};
use super::{Failure, Service, Status, store};

pub(crate) const TOKEN: &str =
    "sk-ant-oat01-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789";
const URL: &str = "https://claude.ai/oauth/authorize?IBO2WCZua9reFW1O9E9nAFQz0QnJ-x0R2bdZLWa0A6uM";

/// A stand-in for `claude setup-token` in `dir`: `body` after a check of its argument.
pub(crate) fn fake_claude(dir: &Path, body: &str) -> PathBuf {
    let path = dir.join("claude");
    std::fs::write(&path, format!("#!/bin/sh\n[ \"$1\" = setup-token ] || exit 9\n{body}\n"))
        .unwrap();
    std::fs::set_permissions(&path, std::os::unix::fs::PermissionsExt::from_mode(0o700)).unwrap();
    path
}

/// The link as Claude Code prints it: an OSC 8 hyperlink, then the plain text on its own line.
pub(crate) fn print_link() -> String {
    format!(
        "printf 'Browser did not open? Use the URL below to sign in\\n\\033]8;id=1;{URL}\\007{URL}\\033]8;;\\007\\n\\nPaste code here if prompted > '"
    )
}

fn service(dir: &Path, program: PathBuf, url_timeout: Duration) -> Arc<Service> {
    let secrets = dir.join("secrets");
    std::fs::create_dir_all(&secrets).unwrap();
    Arc::new(Service::new(Arc::new(store::Files(secrets)), Some(program), url_timeout))
}

/// An `add` that records the reference it was given and answers `answer`.
type Added = Arc<Mutex<Vec<String>>>;
fn adder(answer: Result<&str, &str>) -> (Added, impl FnOnce(&str) -> Result<String, Failure>) {
    let added: Added = Arc::default();
    let seen = added.clone();
    let answer = answer.map(str::to_owned).map_err(str::to_owned);
    (added, move |reference: &str| {
        seen.lock().unwrap().push(reference.to_owned());
        answer.map_err(|why| Failure::new("add", why))
    })
}

fn secrets(dir: &Path) -> Vec<PathBuf> {
    std::fs::read_dir(dir.join("secrets")).unwrap().map(|e| e.unwrap().path()).collect()
}

#[test]
fn the_link_is_read_from_an_osc8_hyperlink_and_its_plain_text_once_whole() {
    let printed = format!("x\x1b[1m\x1b]8;id=1;{URL}\x07{URL}\x1b]8;;\x07\r\n");
    assert_eq!(find_url(printed.as_bytes()).as_deref(), Some(URL));
    // Cut anywhere before its end, it is not taken yet (it may go on).
    let plain = format!("Use the URL below: {URL}");
    assert_eq!(find_url(plain.as_bytes()), None);
    assert_eq!(find_url(format!("{plain}\r").as_bytes()).as_deref(), Some(URL));
    let long = "https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c&state=x";
    assert_eq!(find_url(format!("{long} ").as_bytes()).as_deref(), Some(long));
    assert_eq!(find_url(b"https://example.com/oauth/authorize?x \n"), None);
    assert_eq!(strip_ansi(b"\x1b[32mok\x1b[0m\x1b]0;title\x1b\\!"), b"ok!");
}

#[tokio::test(flavor = "multi_thread")]
async fn begin_answers_the_link_and_wait_stores_the_token_and_answers_only_its_reference() {
    let dir = tempfile::tempdir().unwrap();
    let browser = dir.path().join("browser");
    let body = format!(
        "printf '%s|%s|%s' \"$BROWSER\" \"${{ANTHROPIC_API_KEY-unset}}\" \"${{CLAUDE_CODE_OAUTH_TOKEN-unset}}\" > '{}'\n{}\nsleep 0.3\nprintf '\\n\\033[32m{TOKEN}\\033[0m\\nStore this token securely\\n'\nsleep 30",
        browser.display(),
        print_link()
    );
    let svc = service(dir.path(), fake_claude(dir.path(), &body), Duration::from_secs(10));
    let (added, add) = adder(Ok("claude-token"));
    let finished: Arc<Mutex<Option<Status>>> = Arc::default();
    let seen = finished.clone();
    let started = Instant::now();
    let begun = svc.begin(add, move |s| *seen.lock().unwrap() = Some(s.clone())).await.unwrap();
    assert_eq!(begun.url.as_deref(), Some(URL));
    let status = svc.wait(&begun.attempt, Duration::from_secs(10)).await.unwrap();
    assert_eq!(status, Status::Done("claude-token".into()));
    assert!(started.elapsed() < Duration::from_secs(15), "the child after the token is ended");
    assert_eq!(*finished.lock().unwrap(), Some(status.clone()));
    let references = added.lock().unwrap().clone();
    assert_eq!(references.len(), 1);
    assert!(references[0].starts_with("file:") && !references[0].contains(TOKEN));
    let files = secrets(dir.path());
    assert_eq!(files.len(), 1);
    assert!(files[0].file_name().unwrap().to_string_lossy().starts_with("claude-token-"));
    assert_eq!(std::fs::read_to_string(&files[0]).unwrap().trim(), TOKEN);
    assert_eq!(std::fs::read_to_string(&browser).unwrap(), "/usr/bin/true|unset|unset");
    for answer in [format!("{begun:?}"), format!("{status:?}")] {
        assert!(!answer.contains("sk-ant"), "{answer}");
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn code_types_the_code_without_whitespace_and_return() {
    let dir = tempfile::tempdir().unwrap();
    let got = dir.path().join("got");
    let body = format!(
        "{}\nread code\nprintf '%s' \"$code\" > '{}'\nprintf '{TOKEN}\\n'\nsleep 30",
        print_link(),
        got.display()
    );
    let svc = service(dir.path(), fake_claude(dir.path(), &body), Duration::from_secs(10));
    let (_, add) = adder(Ok("claude-token"));
    let begun = svc.begin(add, |_| {}).await.unwrap();
    assert_eq!(
        svc.wait(&begun.attempt, Duration::from_millis(300)).await.unwrap(),
        Status::Pending
    );
    let bad = svc.code(&begun.attempt, " \n ").await.unwrap_err();
    assert_eq!(bad.code, "bad_code");
    svc.code(&begun.attempt, "  ab-12 \n 34\tCD \r\n").await.unwrap();
    let status = svc.wait(&begun.attempt, Duration::from_secs(10)).await.unwrap();
    assert_eq!(status, Status::Done("claude-token".into()));
    assert_eq!(std::fs::read_to_string(&got).unwrap(), "ab-1234CD");
    let late = svc.code(&begun.attempt, "x").await.unwrap_err();
    assert_eq!(late.code, "not_pending");
}

fn alive(pid_file: &Path) -> bool {
    let pid: libc::pid_t = std::fs::read_to_string(pid_file).unwrap().trim().parse().unwrap();
    // SAFETY: signal 0 only asks whether the process exists.
    unsafe { libc::kill(pid, 0) == 0 }
}

#[tokio::test(flavor = "multi_thread")]
async fn cancel_ends_the_child_and_a_new_begin_cancels_the_pending_one() {
    let dir = tempfile::tempdir().unwrap();
    let pid = dir.path().join("pid");
    let body = format!("echo $$ > '{}'\n{}\nsleep 30", pid.display(), print_link());
    let svc = service(dir.path(), fake_claude(dir.path(), &body), Duration::from_secs(10));
    let (_, add) = adder(Ok("claude-token"));
    let first = svc.begin(add, |_| {}).await.unwrap();
    assert!(alive(&pid));
    let (_, add) = adder(Ok("claude-token"));
    let second = svc.begin(add, |_| {}).await.unwrap();
    assert_eq!(svc.wait(&first.attempt, Duration::ZERO).await.unwrap(), Status::Cancelled);
    assert!(alive(&pid), "the second child runs");
    let started = Instant::now();
    assert_eq!(svc.cancel(&second.attempt).await.unwrap(), Status::Cancelled);
    assert!(started.elapsed() < Duration::from_secs(5));
    assert!(!alive(&pid), "cancel ended the child");
    assert_eq!(svc.wait(&second.attempt, Duration::from_secs(1)).await.unwrap(), Status::Cancelled);
    assert_eq!(svc.cancel("nope").await.unwrap_err().code, "unknown_attempt");
    assert!(secrets(dir.path()).is_empty());
}

#[tokio::test(flavor = "multi_thread")]
async fn no_link_in_time_ends_the_child_with_no_url() {
    let dir = tempfile::tempdir().unwrap();
    let pid = dir.path().join("pid");
    let body =
        format!("echo $$ > '{}'\necho 'Opening browser to sign in'\nsleep 30", pid.display());
    let svc = service(dir.path(), fake_claude(dir.path(), &body), Duration::from_millis(700));
    let (_, add) = adder(Ok("claude-token"));
    let started = Instant::now();
    let failure = svc.begin(add, |_| {}).await.unwrap_err();
    assert_eq!(failure.code, "no_url");
    assert!(failure.message.contains("Opening browser"), "{}", failure.message);
    assert!(started.elapsed() < Duration::from_secs(6));
    assert!(!alive(&pid), "the child was ended");

    let failing = fake_claude(dir.path(), "echo 'Error: login failed'\nexit 1");
    let svc = service(dir.path(), failing, Duration::from_secs(10));
    let (_, add) = adder(Ok("claude-token"));
    let failure = svc.begin(add, |_| {}).await.unwrap_err();
    assert_eq!(failure.code, "no_url");
    assert!(failure.message.contains("login failed"), "{}", failure.message);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_missing_claude_is_no_claude() {
    let dir = tempfile::tempdir().unwrap();
    let svc = service(dir.path(), dir.path().join("no-such-claude"), Duration::from_secs(1));
    let (_, add) = adder(Ok("claude-token"));
    let failure = svc.begin(add, |_| {}).await.unwrap_err();
    assert_eq!(failure.code, "no_claude");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_refused_add_deletes_the_stored_token() {
    let dir = tempfile::tempdir().unwrap();
    let body = format!("{}\nprintf '\\n{TOKEN}\\n'\nsleep 30", print_link());
    let svc = service(dir.path(), fake_claude(dir.path(), &body), Duration::from_secs(10));
    let (added, add) = adder(Err("refused"));
    let begun = svc.begin(add, |_| {}).await.unwrap();
    let status = svc.wait(&begun.attempt, Duration::from_secs(10)).await.unwrap();
    assert_eq!(status, Status::Failed("add".into()));
    assert_eq!(added.lock().unwrap().len(), 1);
    assert!(secrets(dir.path()).is_empty(), "the item was deleted");
}
