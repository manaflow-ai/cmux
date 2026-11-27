use super::*;

fn env<'a>(pairs: &'a [(&'a str, &'a str)]) -> impl Fn(&str) -> Option<String> + 'a {
    move |key| pairs.iter().find(|(k, _)| *k == key).map(|(_, v)| (*v).to_owned())
}

const DESKTOP: [(&str, &str); 5] = [
    ("CLAUDECODE", "1"),
    ("CLAUDE_CODE_ENTRYPOINT", "claude-desktop"),
    ("CLAUDE_CODE_SESSION_ID", "03214B87-953d-4ecf-98ae-93d337878273"),
    ("CLAUDE_CODE_MESSAGING_SOCKET", "/tmp/cc-socks/42.sock"),
    ("CLAUDE_CODE_MESSAGING_TOKEN", "tok"),
];

fn with(extra: &[(&'static str, &'static str)]) -> Vec<(&'static str, &'static str)> {
    DESKTOP.iter().copied().chain(extra.iter().copied()).collect()
}

fn swap(key: &str, value: &'static str) -> Vec<(&'static str, &'static str)> {
    DESKTOP.iter().map(|&(k, v)| (k, if k == key { value } else { v })).collect()
}

#[cfg(unix)]
#[tokio::test]
async fn renew_hook_uses_one_frame_even_when_the_daemon_is_late() {
    use crate::rpc::{Message, method};
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("daemon.sock");
    let listener = tokio::net::UnixListener::bind(&socket).unwrap();
    for late in [false, true] {
        let want = auto_register_in(env(&DESKTOP), false).unwrap();
        let path = socket.clone();
        let hook = tokio::spawn(async move { renew_at(&path, want, RENEW_WAIT).await });
        let (stream, _) = listener.accept().await.unwrap();
        let (rd, mut wr) = stream.into_split();
        let mut lines = BufReader::new(rd).lines();
        let line = lines.next_line().await.unwrap().unwrap();
        let Message::Request { id, method, params } = Message::parse(&line).unwrap() else {
            panic!("expected registration");
        };
        assert_eq!(method, method::MUX_REGISTER);
        assert_eq!(params.unwrap()["renew"], true);
        if late {
            tokio::time::pause();
            tokio::time::advance(RENEW_WAIT).await;
            let reply = hook.await.unwrap();
            assert!(reply["renewed"].is_null());
            assert_eq!(reply["retryable"], true);
            tokio::time::resume();
        } else {
            wr.write_all(Message::ok(id, json!({"renewed": true})).to_line().as_bytes())
                .await
                .unwrap();
            assert_eq!(hook.await.unwrap(), json!({"renewed": true}));
        }
        assert!(lines.next_line().await.unwrap().is_none(), "exactly one request");
    }
}

#[cfg(unix)]
#[tokio::test]
async fn renew_hook_distinguishes_a_missing_daemon_from_its_refusal() {
    use crate::rpc::{Message, RpcError};
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("daemon.sock");
    let want = auto_register_in(env(&DESKTOP), false).unwrap();
    let absent = renew_at(&socket, want.clone(), RENEW_WAIT).await;
    assert!(absent["renewed"].is_null());
    assert_eq!(absent["retryable"], true);

    let listener = tokio::net::UnixListener::bind(&socket).unwrap();
    let hook = tokio::spawn(async move { renew_at(&socket, want, RENEW_WAIT).await });
    let (stream, _) = listener.accept().await.unwrap();
    let (rd, mut wr) = stream.into_split();
    let line = BufReader::new(rd).lines().next_line().await.unwrap().unwrap();
    let Message::Request { id, .. } = Message::parse(&line).unwrap() else {
        panic!("expected renewal");
    };
    wr.write_all(Message::err(id, RpcError::invalid_params("wrong inbox")).to_line().as_bytes())
        .await
        .unwrap();
    let refusal = hook.await.unwrap();
    assert_eq!(refusal["renewed"], false);
    assert_eq!(refusal["reason"], "wrong inbox");
}

/// Repro (ask-828b64b532): a desktop chat on cosmic-gray that never registered sent the
/// coordinator a question, and nothing could answer it. Its send now starts registering it,
/// under the same name on every send.
#[test]
fn an_unregistered_claude_code_chats_send_starts_its_registration() {
    let want = auto_register_in(env(&DESKTOP), false).expect("registers");
    assert_eq!(want.name, "claude-desktop-03214b87");
    assert_eq!(want.socket, "/tmp/cc-socks/42.sock");
    assert_eq!(want.token, "tok");
    assert_eq!(auto_register_in(env(&DESKTOP), false), Some(want), "the same name again");
    let vscode = swap("CLAUDE_CODE_ENTRYPOINT", "claude-vscode");
    assert_eq!(auto_register_in(env(&vscode), false).unwrap().name, "claude-vscode-03214b87");
    let cli = swap("CLAUDE_CODE_ENTRYPOINT", "cli");
    assert_eq!(auto_register_in(env(&cli), false).unwrap().name, "claude-code-03214b87");
}

/// A sender with an address, a named one, the person's own send, or a shell with no inbox
/// starts nothing.
#[test]
fn a_send_with_an_address_or_no_inbox_starts_nothing() {
    assert_eq!(auto_register_in(env(&DESKTOP), true), None, "--from");
    let from = with(&[(crate::cli::sender::FROM_ENV, "reach-lane")]);
    assert_eq!(auto_register_in(env(&from), false), None, "ACPMUX_FROM");
    let inside = with(&[("ACPMUX_SESSION_ID", "s1"), ("ACPMUX_SESSION_TOKEN", "t")]);
    assert_eq!(auto_register_in(env(&inside), false), None, "an acpmux session");
    for missing in [
        "CLAUDECODE",
        "CLAUDE_CODE_MESSAGING_SOCKET",
        "CLAUDE_CODE_MESSAGING_TOKEN",
        "CLAUDE_CODE_SESSION_ID",
    ] {
        let without: Vec<_> = DESKTOP.iter().copied().filter(|(k, _)| *k != missing).collect();
        assert_eq!(auto_register_in(env(&without), false), None, "no {missing}");
    }
    let odd = swap("CLAUDE_CODE_SESSION_ID", "--");
    assert_eq!(auto_register_in(env(&odd), false), None, "no word to name it by");
    assert_eq!(auto_register_in(env(&[("CODEX_THREAD_ID", "t-1")]), false), None, "Codex");
    assert_eq!(auto_register_in(env(&[]), false), None, "the person's terminal");
}

fn said(v: Value) -> Option<String> {
    line("claude-desktop-03214b87", "cosmic-gray", Outcome::Answer(v))
}

#[test]
fn the_send_says_what_the_chat_must_do_until_it_is_registered() {
    let shown = said(json!({"pending": true, "name": "claude-desktop-03214b87"})).unwrap();
    assert_eq!(
        shown,
        "the receiver cannot reply to this chat until it is registered: a one-time code is in this chat's inbox (a message from acpmux); run the `acpmux register claude-desktop-03214b87 --code ...` it gives, and replies then reach cosmic-gray/claude-desktop-03214b87"
    );
    // A chat registered before as desktop-zoe (or a code `register desktop-zoe` asked
    // for): the daemon's name is the one.
    let shown = said(json!({"pending": true, "resent": false, "name": "desktop-zoe"})).unwrap();
    assert!(shown.ends_with("reach cosmic-gray/desktop-zoe"), "{shown}");
    // Another send's step is running: a code is coming, its name not known yet.
    let shown = said(json!({"pending": true, "resent": false})).unwrap();
    assert!(shown.contains("a one-time code is coming"), "{shown}");
    assert!(!shown.contains("claude-desktop-03214b87"), "{shown}");
    let failed =
        line("claude-desktop-03214b87", "h", Outcome::Refused("register.unproven: x".into()));
    assert_eq!(
        failed.as_deref(),
        Some(
            "the receiver cannot reply to this chat: it has no acpmux address, and registering it did not start (register.unproven: x); run `acpmux register claude-desktop-03214b87` in this shell, then the `--code` line it delivers"
        )
    );
}

/// Nothing to say once the chat has an address (registered, or reached by the bridge), or
/// for a failure an earlier send already reported.
#[test]
fn a_chat_with_an_address_or_a_failure_already_told_prints_nothing() {
    assert_eq!(said(json!({"registered": true, "name": "desktop-zoe"})), None);
    assert_eq!(said(json!({"reachable": true, "name": null})), None);
    assert_eq!(said(json!({"failed": "register.unproven: x", "repeat": true})), None);
}

/// Repro: the 3 s wait ran out and the send said registering "did not start" and to run
/// `acpmux register NAME`, while the daemon went on and delivered the code; that manual
/// register would send a second code, which replaces the first.
#[test]
fn no_answer_in_time_says_a_code_may_still_come_and_asks_for_no_second() {
    let shown = line("claude-desktop-03214b87", "h", Outcome::NoAnswer).unwrap();
    assert!(shown.contains("a one-time code may still arrive"), "{shown}");
    assert!(!shown.contains("did not start"), "{shown}");
    assert!(!shown.contains("run `acpmux register claude-desktop-03214b87`"), "{shown}");
}

/// Repro: an older daemon ignores `auto` and delivers a code on every send. A daemon that
/// does not list the feature is not asked; the wait takes at most half of what is left before
/// the send's deadline, so a short `--timeout` send still has time to go out.
#[test]
fn only_a_daemon_that_takes_auto_is_asked_and_never_past_the_deadline() {
    let now = tokio::time::Instant::now();
    assert_eq!(wait_for(false, None, now), None, "an older daemon");
    assert_eq!(wait_for(true, None, now), Some(WAIT));
    let soon = now + Duration::from_millis(500);
    assert_eq!(wait_for(true, Some(soon), now), Some(Duration::from_millis(250)));
    let two = now + Duration::from_secs(2);
    assert_eq!(wait_for(true, Some(two), now), Some(Duration::from_secs(1)), "--timeout 2");
    assert_eq!(wait_for(true, Some(now + Duration::from_secs(60)), now), Some(WAIT));
    assert_eq!(wait_for(true, Some(now), now), None, "the deadline passed");
}
