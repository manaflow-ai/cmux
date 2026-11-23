//! `try-pr` (`try-pr-v1`): cmux Dev's Try a pull request picker (Settings > Developer),
//! served by the Mac the phone is attached to (cmuxterm-hq docs/design/ios-dev-channels.md,
//! iPhone DEV step 3).
//!
//! The Mac runs `cmux-next-ios/scripts/try.sh` from a cmux checkout: `try.sh list` names the
//! open iPhone pull requests and whether each head's cmux Dev is built ahead (the `cmux Dev
//! try build (ahead)` check), and `try.sh N` downloads that build (or builds it on the fleet),
//! signs it and installs it over cmux Dev on the phones attached to this Mac. hostd finds the
//! script at `$CMUX_MOBILE_TRY_SH`, else `~/.config/cmux/try.sh` (a link to a checkout's
//! script); with neither the service is not offered and `version` leaves out the capability.
//! It runs through the person's login shell, so gh, the cmux-ci client and the signing
//! identity are the ones a terminal on the Mac has.
//!
//! Arguments, one object:
//! - `{"op":"list"}`: one data frame, `try.sh list`'s JSON (`cmux.ios-try.list.v1`), then `eof`.
//! - `{"op":"install","pr":N}`: starts `try.sh N` (or joins the one running for N) and streams
//!   `{"line":"..."}` frames as it prints, then `{"done":true,"pr":N,"exit":code}` and `eof`.
//!   Installing replaces the running cmux Dev, so the channel usually ends with the app; the
//!   install runs on without it, one at a time (`busy` while another PR's runs).
//! - `{"op":"status"}`: one frame `{"run":{"pr","started_ms","lines","exit"?}|null}`, the
//!   last install (its last [`KEEP_LINES`] lines), so the relaunched app can say how it went.
//!
//! Phones only (`peer.rs`: not offered to machines).

use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use bytes::Bytes;
use cmux_mobile_link::link::ChannelSender;
use serde::Serialize;
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, BufReader};
use tokio::sync::watch;

use crate::services::Refusal;

/// The service's name on the link.
pub const SERVICE: &str = "try-pr";
/// The `version` capability that says this host serves [`SERVICE`].
pub const CAPABILITY: &str = cmux_mobile_link::names::TRY_PR;
/// Where the script is, when set.
pub const SCRIPT_ENV: &str = "CMUX_MOBILE_TRY_SH";
/// `try.sh list` asks GitHub once; past this it is stuck.
pub const LIST_TIMEOUT: Duration = Duration::from_secs(120);
/// `try.sh N` may wait for the fleet to build a head nobody built ahead (queue plus build).
pub const INSTALL_TIMEOUT: Duration = Duration::from_secs(4 * 3600);
/// The largest `try.sh list` reply relayed.
pub const MAX_LIST_BYTES: usize = 1024 * 1024;
/// Lines of the last install kept for `status`.
pub const KEEP_LINES: usize = 60;
/// A longer output line is cut to this many characters.
pub const MAX_LINE_CHARS: usize = 400;

/// The script and the shell that runs it.
#[derive(Clone, Debug)]
pub struct Runner {
    pub script: PathBuf,
    pub shell: PathBuf,
}

impl Runner {
    /// The script named by [`SCRIPT_ENV`] or `~/.config/cmux/try.sh`, when it is a file.
    pub fn from_env() -> Option<Self> {
        let script = std::env::var_os(SCRIPT_ENV)
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|home| Path::new(&home).join(".config/cmux/try.sh")))?;
        if !script.is_file() {
            return None;
        }
        let shell = std::env::var_os("SHELL")
            .map(PathBuf::from)
            .filter(|shell| shell.is_absolute())
            .unwrap_or_else(|| PathBuf::from("/bin/zsh"));
        Some(Self { script, shell })
    }

    fn command(&self, args: &[String]) -> tokio::process::Command {
        // A login shell for the person's PATH; the script and its arguments stay out of the
        // command text ($0, $@).
        let mut command = tokio::process::Command::new(&self.shell);
        command
            .arg("-lc")
            .arg("exec \"$0\" \"$@\" 2>&1")
            .arg(&self.script)
            .args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true);
        command
    }

    /// `try.sh list`'s JSON. It prints JSON on its own failures too (`error`), so any reply
    /// that parses is relayed whatever the exit.
    pub async fn list(&self) -> Result<Value, Refusal> {
        let mut child = self
            .command(&["list".to_owned()])
            .spawn()
            .map_err(|error| Refusal::new("unavailable", format!("could not run try.sh: {error}")))?;
        let mut stdout = child.stdout.take().expect("piped");
        let mut out = Vec::new();
        let read = async {
            (&mut stdout).take(MAX_LIST_BYTES as u64 + 1).read_to_end(&mut out).await?;
            child.wait().await
        };
        match tokio::time::timeout(LIST_TIMEOUT, read).await {
            Err(_) => return Err(Refusal::new("timeout", "try.sh list did not answer in 2 minutes")),
            Ok(Err(error)) => return Err(Refusal::new("unavailable", format!("try.sh list: {error}"))),
            Ok(Ok(_)) => {}
        }
        if out.len() > MAX_LIST_BYTES {
            return Err(Refusal::new("unavailable", "try.sh list printed more than 1 MB"));
        }
        // The JSON is the last line (a login shell may print before it).
        let text = String::from_utf8_lossy(&out);
        text.lines()
            .rev()
            .find(|line| line.trim_start().starts_with('{'))
            .and_then(|line| serde_json::from_str::<Value>(line).ok())
            .filter(|value| value.get("prs").is_some_and(Value::is_array))
            .ok_or_else(|| {
                Refusal::new("unavailable", format!("try.sh list printed no list: {}", tail(&text)))
            })
    }
}

fn tail(text: &str) -> String {
    let last = text.lines().rev().find(|line| !line.trim().is_empty()).unwrap_or("nothing");
    clean_line(last)
}

/// One output line made safe to show: control characters and terminal escapes dropped, cut
/// to [`MAX_LINE_CHARS`].
pub fn clean_line(line: &str) -> String {
    let mut out = String::new();
    let mut chars = line.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\u{1b}' {
            // CSI: ESC [ ... final byte in @..~
            if chars.peek() == Some(&'[') {
                chars.next();
                for c in chars.by_ref() {
                    if ('@'..='~').contains(&c) {
                        break;
                    }
                }
            }
            continue;
        }
        if c == '\t' {
            out.push(' ');
        } else if !c.is_control() {
            out.push(c);
        }
        if out.chars().count() >= MAX_LINE_CHARS {
            break;
        }
    }
    out
}

/// One install, as `status` and the stream show it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct Run {
    pub pr: u64,
    pub started_ms: i64,
    pub lines: VecDeque<String>,
    /// How many lines it printed in all (the stream sends the ones past what it sent).
    #[serde(skip)]
    pub printed: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub exit: Option<i32>,
}

/// The installs this host runs, one at a time.
pub struct Installs {
    current: Mutex<Option<watch::Sender<Run>>>,
}

impl Installs {
    pub const fn new() -> Self {
        Self { current: Mutex::new(None) }
    }

    /// The last install, running or done.
    pub fn last(&self) -> Option<Run> {
        self.current.lock().unwrap().as_ref().map(|run| run.borrow().clone())
    }

    /// Start `try.sh pr`, or join the one running for `pr`; `busy` while another runs.
    pub fn start(&self, runner: &Runner, pr: u64) -> Result<watch::Receiver<Run>, Refusal> {
        let mut current = self.current.lock().unwrap();
        if let Some(run) = current.as_ref() {
            let state = run.borrow();
            if state.exit.is_none() {
                if state.pr == pr {
                    return Ok(run.subscribe());
                }
                return Err(Refusal::new("busy", format!("this Mac is installing #{} now", state.pr)));
            }
        }
        let mut child = runner
            .command(&[pr.to_string()])
            .spawn()
            .map_err(|error| Refusal::new("unavailable", format!("could not run try.sh: {error}")))?;
        let stdout = child.stdout.take().expect("piped");
        let (tx, rx) = watch::channel(Run { pr, started_ms: crate::activity::now_ms(), ..Run::default() });
        *current = Some(tx.clone());
        tokio::spawn(async move {
            let mut lines = BufReader::new(stdout).lines();
            let run = async {
                while let Ok(Some(line)) = lines.next_line().await {
                    let line = clean_line(&line);
                    tx.send_modify(|run| {
                        run.lines.push_back(line);
                        while run.lines.len() > KEEP_LINES {
                            run.lines.pop_front();
                        }
                        run.printed += 1;
                    });
                }
                child.wait().await
            };
            let exit = match tokio::time::timeout(INSTALL_TIMEOUT, run).await {
                Ok(Ok(status)) => status.code().unwrap_or(-1),
                Ok(Err(error)) => {
                    tracing::warn!(pr, %error, "try.sh install");
                    -1
                }
                Err(_) => {
                    tracing::warn!(pr, "try.sh install ran past its bound; stopped");
                    -2
                }
            };
            tracing::info!(pr, exit, "try.sh install ended");
            tx.send_modify(|run| run.exit = Some(exit));
        });
        Ok(rx)
    }
}

impl Default for Installs {
    fn default() -> Self {
        Self::new()
    }
}

static INSTALLS: Installs = Installs::new();
static RUNNER: OnceLock<Option<Runner>> = OnceLock::new();

/// The script this host would run, looked up once.
pub fn runner() -> Option<&'static Runner> {
    RUNNER.get_or_init(Runner::from_env).as_ref()
}

/// Whether `version` lists [`CAPABILITY`].
pub fn available() -> bool {
    runner().is_some()
}

#[derive(Debug, PartialEq, Eq)]
pub enum Op {
    List,
    Status,
    Install(u64),
}

/// The phone's arguments, checked.
pub fn parse(args: &Value) -> Result<Op, Refusal> {
    let object = args.as_object().ok_or_else(|| Refusal::new("bad_request", "try-pr takes an object"))?;
    let only = |keys: &[&str]| object.keys().all(|key| keys.contains(&key.as_str()));
    match object.get("op").and_then(Value::as_str) {
        Some("list") if only(&["op"]) => Ok(Op::List),
        Some("status") if only(&["op"]) => Ok(Op::Status),
        Some("install") if only(&["op", "pr"]) => object
            .get("pr")
            // The phone's channel arguments are strings ("48991"); a number reads too.
            .and_then(|pr| match pr {
                Value::String(text) if text.bytes().all(|b| b.is_ascii_digit()) => text.parse().ok(),
                _ => pr.as_u64(),
            })
            .filter(|pr| (1..=99_999_999).contains(pr))
            .map(Op::Install)
            .ok_or_else(|| Refusal::new("bad_request", "install needs pr, a pull request number")),
        _ => Err(Refusal::new("bad_request", "try-pr takes op list, status or install with pr")),
    }
}

async fn send(sender: &ChannelSender, value: &Value) -> Result<(), Refusal> {
    sender
        .send(Bytes::from(value.to_string()))
        .await
        .map_err(|_| Refusal::new("closed", "phone channel closed"))
}

pub async fn serve(sender: &ChannelSender, args: &Value) -> Result<(), Refusal> {
    let op = parse(args)?;
    let runner = runner().ok_or_else(|| {
        Refusal::new(
            "unavailable",
            format!("this Mac has no try.sh (link a cmux checkout's cmux-next-ios/scripts/try.sh to ~/.config/cmux/try.sh or set {SCRIPT_ENV})"),
        )
    })?;
    match op {
        Op::List => send(sender, &runner.list().await?).await,
        Op::Status => send(sender, &serde_json::json!({ "run": INSTALLS.last() })).await,
        Op::Install(pr) => stream(sender, INSTALLS.start(runner, pr)?).await,
    }
}

/// Every line of the install from its start (those still kept), then its end.
async fn stream(sender: &ChannelSender, mut run: watch::Receiver<Run>) -> Result<(), Refusal> {
    let mut sent = 0u64;
    loop {
        let state = run.borrow_and_update().clone();
        let unsent = state.printed.saturating_sub(sent).min(state.lines.len() as u64) as usize;
        for line in state.lines.iter().skip(state.lines.len() - unsent) {
            send(sender, &serde_json::json!({ "line": line })).await?;
        }
        sent = state.printed;
        if let Some(exit) = state.exit {
            return send(sender, &serde_json::json!({ "done": true, "pr": state.pr, "exit": exit })).await;
        }
        if run.changed().await.is_err() {
            return Err(Refusal::new("unavailable", "the install stopped"));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn script(dir: &Path, body: &str) -> Runner {
        let path = dir.join("try.sh");
        std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        Runner { script: path, shell: PathBuf::from("/bin/sh") }
    }

    #[test]
    fn only_the_three_ops_with_a_real_number_pass() {
        assert_eq!(parse(&serde_json::json!({"op": "list"})).unwrap(), Op::List);
        assert_eq!(parse(&serde_json::json!({"op": "status"})).unwrap(), Op::Status);
        assert_eq!(parse(&serde_json::json!({"op": "install", "pr": 48991})).unwrap(), Op::Install(48991));
        assert_eq!(parse(&serde_json::json!({"op": "install", "pr": "48991"})).unwrap(), Op::Install(48991));
        for bad in [
            serde_json::json!({"op": "install"}),
            serde_json::json!({"op": "install", "pr": 0}),
            serde_json::json!({"op": "install", "pr": -3}),
            serde_json::json!({"op": "install", "pr": "+3"}),
            serde_json::json!({"op": "install", "pr": ""}),
            serde_json::json!({"op": "install", "pr": "48991; rm -rf ~"}),
            serde_json::json!({"op": "install", "pr": 1, "device": "x"}),
            serde_json::json!({"op": "list", "pr": 1}),
            serde_json::json!({"op": "run"}),
            serde_json::json!([]),
        ] {
            assert_eq!(parse(&bad).unwrap_err().code, "bad_request", "{bad}");
        }
    }

    #[test]
    fn lines_lose_escapes_and_control_characters() {
        assert_eq!(clean_line("\u{1b}[1;32mok\u{1b}[0m\tdone\r"), "ok done");
        assert_eq!(clean_line(&"x".repeat(1000)).len(), MAX_LINE_CHARS);
    }

    #[tokio::test]
    async fn list_relays_the_scripts_json_even_on_its_error() {
        let dir = tempfile::tempdir().unwrap();
        let runner = script(
            dir.path(),
            r#"[ "$1" = list ] || exit 9
echo 'noise from a profile'
echo '{"schema":"cmux.ios-try.list.v1","error":"gh is not signed in","prs":[]}'
exit 1"#,
        );
        let list = runner.list().await.unwrap();
        assert_eq!(list["error"], "gh is not signed in");
        let broken = script(dir.path(), "echo 'gh: command not found'; exit 127");
        let refusal = broken.list().await.unwrap_err();
        assert_eq!(refusal.code, "unavailable");
        assert!(refusal.reason.contains("gh: command not found"), "{}", refusal.reason);
    }

    #[tokio::test]
    async fn one_install_at_a_time_and_its_lines_and_exit_stay_for_status() {
        let dir = tempfile::tempdir().unwrap();
        let gate = dir.path().join("go");
        let runner = script(
            dir.path(),
            &format!(
                "echo \"installing #$1\"; while [ ! -e '{}' ]; do sleep 0.05; done; echo 'try: installed' >&2; exit 3",
                gate.display()
            ),
        );
        let installs = Installs::new();
        let mut first = installs.start(&runner, 7).unwrap();
        // The same PR joins the running install; another is refused.
        let _joined = installs.start(&runner, 7).unwrap();
        assert_eq!(installs.start(&runner, 8).unwrap_err().code, "busy");
        std::fs::write(&gate, "").unwrap();
        let done = first.wait_for(|run| run.exit.is_some()).await.unwrap().clone();
        assert_eq!(done.exit, Some(3));
        assert_eq!(Vec::from(done.lines.clone()), vec!["installing #7", "try: installed"]);
        assert_eq!(installs.last().unwrap(), done);
        // Done, so the next PR may start.
        let mut next = installs.start(&runner, 8).unwrap();
        assert_eq!(next.borrow_and_update().pr, 8);
    }
}
