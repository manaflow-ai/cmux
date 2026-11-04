//! The `acpmux` MCP server's tools against a daemon with the fake agent behind a real socket.

use super::*;
use crate::config::{Config, HarnessProfile, PermissionPolicy, StoreMode};
use cmux_json::JsonSet as _;
use std::collections::BTreeMap;

async fn daemon() -> (Arc<crate::hub::Hub>, Arc<Client>, cmux_unix_socket::TestDir) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut harnesses = BTreeMap::new();
    harnesses.insert(
        "fake".to_owned(),
        HarnessProfile {
            kind: Default::default(),
            argv: vec!["python3".into(), fake.into()],
            env: BTreeMap::new(),
            description: None,
            fallback: None,
            family: None,
            models: vec![],
            model: None,
            effort: None,
            policy: None,
        },
    );
    let mut cfg = Config { harnesses, default_harness: Some("fake".into()), ..Default::default() };
    cfg.store.mode = StoreMode::Memory;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = crate::hub::Hub::new(cfg, store);
    let dir = cmux_unix_socket::short_test_dir("acpmux-mcp");
    let path = dir.path().join("d.sock");
    let listener = crate::server::bind_unix(&path).await.unwrap();
    tokio::spawn(crate::server::serve_unix(hub.clone(), listener));
    let client = Client::connect(&path).await.unwrap();
    (hub, client, dir)
}

async fn session(client: &Arc<Client>, name: &str) -> String {
    let s = client
        .request(
            method::SESSION_NEW,
            json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": name}}}),
        )
        .await
        .unwrap();
    s["sessionId"].as_str().unwrap().to_owned()
}

fn tool(name: &str, arguments: Value) -> Value {
    json!({"name": name, "arguments": arguments})
}

fn text(result: &Value) -> String {
    result["content"][0]["text"].as_str().unwrap_or_default().to_owned()
}

#[test]
fn the_tools_say_they_message_other_sessions_instead_of_the_shell() {
    let tools = tools();
    let names: Vec<&str> =
        tools.as_array().unwrap().iter().filter_map(|t| t["name"].as_str()).collect();
    assert_eq!(
        names,
        [
            "send",
            "inbox_read",
            "inbox_reply",
            "ls",
            "last",
            "info",
            "team_send",
            "team_inbox",
            "team_ack",
            "search",
            "github_status",
            "bg_start",
            "bg_list",
            "bg_output",
            "bg_stop",
            "run_wait",
            "pr_state",
            "wrap_up"
        ]
    );
    let send = tools[0]["description"].as_str().unwrap();
    assert!(send.contains("Message another agent session"), "{send}");
    assert!(send.contains("instead of running `acpmux send` in a shell"), "{send}");
    assert!(send.contains("batch them in one call with messages"), "{send}");
    assert_eq!(tools[6]["inputSchema"]["required"], json!(["to", "body"]));
    assert_eq!(tools[8]["inputSchema"]["required"], json!(["id"]));
}

/// The first shape's fields are as they were (a snapshot): only new optional fields were added,
/// and `required` went, because a batch names its recipients and texts in `messages`; a call
/// without them is still refused for want of to and text (below).
#[test]
fn the_send_schema_keeps_its_first_shape() {
    let props = &tools()[0]["inputSchema"]["properties"];
    let first = json!({
        "to": {"type": "string", "description": "The session: its name, id, or host/name for a session on a peer (as ls lists them)."},
        "text": {"type": "string", "description": "The message, self-contained."},
        "steer": {"type": "boolean", "description": "true (default): into a running turn at its next tool step. false: queued behind the running turn."},
        "class": {"type": "string", "enum": ["block", "question", "result", "fyi", "blocker", "action"], "description": "What the message asks of the receiver: block or blocker (you cannot go on until it acts; wakes an idle receiver), question (you wait for its answer; wakes it too), result or action (work you finished or work for it; the default; wakes an idle receiver only when you started it or gave it its first work) or fyi (wakes no one)."},
        "pr": {"type": "integer", "description": "The pull request this message is about: the receiver's inbox threads it with the others about it."},
        "thread": {"type": "string", "description": "The thread this message goes in, a topic or a threadId from inbox_read (default: your messages about the PR its first line names, else all your messages)."}
    });
    for (key, want) in first.as_object().unwrap() {
        assert_eq!(&props[key], want, "{key}");
    }
    let mut names: Vec<&String> = props.as_object().unwrap().keys().collect();
    names.sort_unstable();
    assert_eq!(
        names,
        [
            "class",
            "file",
            "messages",
            "notice",
            "pr",
            "steer",
            "supersede",
            "tag",
            "text",
            "thread",
            "to"
        ]
    );
    assert!(tools()[0]["inputSchema"].get("required").is_none());
    let item = &props["messages"]["items"]["properties"];
    let mut item_keys: Vec<&String> = item.as_object().unwrap().keys().collect();
    item_keys.sort_unstable();
    assert_eq!(
        item_keys,
        ["class", "file", "notice", "pr", "steer", "supersede", "tag", "text", "thread", "to"]
    );
    assert_eq!(props["notice"]["required"], json!(["severity", "title"]));
    assert_eq!(props["notice"]["properties"]["severity"]["enum"], json!(["info", "warn", "fire"]));
    assert_eq!(props["messages"]["maxItems"], json!(send::MAX_MESSAGES));
}

/// Waits for a user message carrying `needle` in `session`'s log.
async fn received(hub: &crate::hub::Hub, session: &str, needle: &str) -> bool {
    for _ in 0..100 {
        let events = hub.events(session, 0, 1000).unwrap();
        if events.iter().any(|e| e.kind == "user_message" && e.msg.to_string().contains(needle)) {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    false
}

/// A batch of three with one bad recipient: two rows sent, one row with its error, and the bad
/// one stops neither of the others (the one after it still goes).
#[tokio::test]
async fn a_batch_sends_every_good_recipient_and_names_the_bad_one() {
    let (hub, client, _dir) = daemon().await;
    let a = session(&client, "batch-a").await;
    let b = session(&client, "batch-b").await;
    let args = json!({"class": "fyi", "messages": [
        {"to": "batch-a", "text": "first order"},
        {"to": "nobody-here", "text": "lost"},
        {"to": "batch-b", "text": "second order"}
    ]});
    let started = std::time::Instant::now();
    let r = call(&client, &tool("send", args)).await;
    let took = started.elapsed();
    assert_eq!(r["isError"], false, "{r}");
    let rows = r["structuredContent"]["results"].as_array().unwrap();
    assert_eq!(rows.len(), 3, "{r}");
    let oks: Vec<bool> = rows.iter().map(|r| r["ok"].as_bool().unwrap()).collect();
    assert_eq!(oks, [true, false, true], "{r}");
    assert_eq!(rows[0]["to"], "batch-a");
    assert_eq!(rows[0]["sessionId"], json!(a));
    assert_eq!(rows[2]["sessionId"], json!(b));
    assert_eq!(rows[1]["status"], "failed");
    assert_eq!(rows[1]["index"], 1);
    assert!(rows[1]["error"].as_str().unwrap().contains("nobody-here"), "{r}");
    for row in [&rows[0], &rows[2]] {
        assert!(!row["promptId"].as_str().unwrap().is_empty(), "{row}");
        assert!(!row["deliveryId"].as_str().unwrap().is_empty(), "{row}");
        assert_eq!(row["status"], "delivered", "{row}");
    }
    assert_eq!(r["structuredContent"]["sent"], 2);
    assert_eq!(r["structuredContent"]["failed"], 1);
    assert!(text(&r).ends_with("2 of 3 sent."), "{r}");
    assert!(received(&hub, &a, "first order").await, "batch-a never got its message");
    assert!(received(&hub, &b, "second order").await, "batch-b never got its message");
    // The deliveries settle together: the batch takes no longer than one send's wait.
    eprintln!("batch of 3 (one bad) answered in {took:?}");
    assert!(took < STATUS_WAIT * 2, "{took:?}");
    // A batch where nothing went is the call's error.
    let none = json!({"messages": [{"to": "nobody-1", "text": "x"}, {"text": "no recipient"}]});
    let r = call(&client, &tool("send", none)).await;
    assert_eq!(r["isError"], true, "{r}");
    assert_eq!(r["structuredContent"]["results"][1]["error"], "to (or tag) is required", "{r}");
}

/// Top-level fields are each item's defaults: one text to many sessions, or many texts to one.
#[test]
fn top_level_fields_are_each_items_defaults() {
    let args = json!({"text": "rebase", "class": "fyi", "steer": false, "messages": [
        {"to": "a"}, {"to": "b", "class": "block", "steer": true}, {"tag": "area=x", "file": "f.md"}
    ]});
    let items: Vec<send::Item> =
        send::items(&args).unwrap().into_iter().map(Result::unwrap).collect();
    assert_eq!(items[0].to.as_deref(), Some("a"));
    assert_eq!(items[0].text.as_deref(), Some("rebase"));
    assert_eq!(items[0].class.as_deref(), Some("fyi"));
    assert!(!items[0].steer);
    assert_eq!(items[1].class.as_deref(), Some("block"));
    assert!(items[1].steer);
    // An item's own message (a file) replaces the default text; its tag the default to.
    assert_eq!((items[2].text.as_deref(), items[2].file.as_deref()), (None, Some("f.md")));
    assert_eq!((items[2].to.as_deref(), items[2].tag.as_deref()), (None, Some("area=x")));
    let both = json!({"messages": [{"to": "a", "tag": "t", "text": "x"}, {"to": "a", "text": "x", "file": "y"}, 3]});
    let errors: Vec<String> =
        send::items(&both).unwrap().into_iter().map(Result::unwrap_err).collect();
    assert_eq!(
        errors,
        ["give to or tag, not both", "give text or file, not both", "not an object"]
    );
    assert!(send::items(&json!({"messages": []})).is_err());
    let many: Vec<Value> =
        (0..=send::MAX_MESSAGES).map(|_| json!({"to": "a", "text": "x"})).collect();
    assert!(send::items(&json!({"messages": many})).unwrap_err().contains("at most 32"));
}

/// `notice`: a tool's notice, checked as the daemon checks it, its sender this session's name by
/// default, its links `{url, label?}` or `--link` strings; the text (optional) is its body.
#[tokio::test]
async fn a_notice_argument_is_checked_and_defaults_its_sender_and_host() {
    let env = |pairs: &'static [(&'static str, &'static str)]| {
        move |k: &str| pairs.iter().find(|(key, _)| *key == k).map(|(_, v)| (*v).to_owned())
    };
    let given = json!({"severity": "fire", "title": "fast tier failed", "host": "ci-mini-3",
                       "links": [{"url": "https://x.dev/pull/1", "label": "#1"}, "https://x.dev/run/2=run 2"]});
    let notice =
        send::notice_arg(Some(&given), env(&[("ACPMUX_SESSION_NAME", "lane-1")])).unwrap().unwrap();
    assert_eq!(
        notice,
        json!({"sender": "lane-1", "host": "ci-mini-3", "severity": "fire", "title": "fast tier failed",
               "links": [{"url": "https://x.dev/pull/1", "label": "#1"}, {"url": "https://x.dev/run/2", "label": "run 2"}]})
    );
    let named = json!({"sender": "base-red-watch", "severity": "info", "title": "t", "host": "h"});
    let kept = send::notice_arg(Some(&named), env(&[("ACPMUX_SESSION_NAME", "lane-1")])).unwrap();
    assert_eq!(kept.unwrap()["sender"], "base-red-watch");
    assert_eq!(send::notice_arg(None, env(&[])).unwrap(), None);
    assert_eq!(send::notice_arg(Some(&Value::Null), env(&[])).unwrap(), None);
    let no_sender = json!({"severity": "info", "title": "t"});
    assert!(send::notice_arg(Some(&no_sender), env(&[])).unwrap_err().contains("sender"));
    let loud = json!({"sender": "s", "severity": "loud", "title": "t"});
    assert!(send::notice_arg(Some(&loud), env(&[])).unwrap_err().contains("severity"));
    assert!(send::notice_arg(Some(&json!("fire")), env(&[])).is_err());

    // In a call: the item carries it, its body is optional, and the text is the rendered notice.
    let args = json!({"to": "coord", "notice": {"sender": "s", "host": "h", "severity": "warn", "title": "T"}});
    let mut items: Vec<send::Item> =
        send::items(&args).unwrap().into_iter().map(Result::unwrap).collect();
    assert_eq!(items[0].notice.as_ref().unwrap()["severity"], "warn");
    assert_eq!(send::body(&mut items[0]).await.unwrap().0, "[notice from s on h · WARN] T");
    let dir = tempfile::tempdir().unwrap();
    let empty = dir.path().join("empty.txt");
    std::fs::write(&empty, "").unwrap();
    let mut from_file = send::Item {
        file: Some(empty.to_str().unwrap().to_owned()),
        notice: items[0].notice.clone(),
        ..Default::default()
    };
    assert_eq!(send::body(&mut from_file).await.unwrap().0, "[notice from s on h · WARN] T");
    let bad = json!({"to": "coord", "text": "x", "notice": {"sender": "s", "severity": "fire"}});
    let errors: Vec<String> =
        send::items(&bad).unwrap().into_iter().map(Result::unwrap_err).collect();
    assert!(errors[0].contains("title"), "{errors:?}");
}

/// A notice sent with the tool reaches the receiver as one: its `user_message` carries the notice
/// provenance and the rendered text.
#[tokio::test]
async fn a_notice_sent_with_the_tool_is_recorded_as_a_notice() {
    let (hub, client, _dir) = daemon().await;
    let coord = session(&client, "notice-coord").await;
    let args = json!({"to": "notice-coord", "text": "3 PRs red", "notice": {
        "sender": "base-red-watch", "host": "ci-mini-3", "severity": "fire", "title": "fast tier failed"}});
    let r = call(&client, &tool("send", args)).await;
    assert_eq!(r["isError"], false, "{r}");
    assert!(received(&hub, &coord, "fast tier failed").await, "never received");
    let events = hub.events(&coord, 0, 1000).unwrap();
    let message = events
        .iter()
        .filter(|e| e.kind == "user_message" || e.kind == "inbox")
        .find(|e| e.msg.to_string().contains("fast tier failed"))
        .expect("its record");
    let provenance = &message.msg["_meta"]["provenance"];
    assert_eq!(provenance["kind"], "notice", "{}", message.msg);
    assert_eq!(provenance["fromName"], "base-red-watch", "{}", message.msg);
    assert_eq!(provenance["notice"]["severity"], "fire", "{}", message.msg);
    assert!(
        message
            .msg
            .to_string()
            .contains("[notice from base-red-watch on ci-mini-3 · FIRE] fast tier failed"),
        "{}",
        message.msg
    );
}

/// `file`: small text stays inline, while large files arrive as attachments.
#[tokio::test]
async fn a_message_can_be_a_file_of_yours() {
    let (hub, client, _dir) = daemon().await;
    let lane = session(&client, "file-lane").await;
    let dir = tempfile::tempdir().unwrap();
    let brief = dir.path().join("brief.md");
    std::fs::write(
        &brief,
        "Brief: land #1 when green.
",
    )
    .unwrap();
    let args = json!({"to": "file-lane", "file": brief.to_str().unwrap()});
    let r = call(&client, &tool("send", args)).await;
    assert_eq!(r["isError"], false, "{r}");
    // The first shape's result, as for text.
    assert!(text(&r).starts_with("Sent to file-lane:"), "{r}");
    assert_eq!(r["structuredContent"]["sessionId"], json!(lane), "{r}");
    assert!(received(&hub, &lane, "Brief: land #1 when green.").await, "the file never arrived");

    let binary = dir.path().join("bin");
    std::fs::write(&binary, [0xff, 0xfe, 0x00]).unwrap();
    let empty = dir.path().join("empty");
    std::fs::write(
        &empty, "  
",
    )
    .unwrap();
    let cases = [
        (binary, "not UTF-8 text"),
        (empty, "the file is empty"),
        (dir.path().to_owned(), "not a regular file"),
        (dir.path().join("missing"), "cannot read"),
    ];
    for (path, want) in cases {
        let r = call(&client, &tool("send", json!({"to": "file-lane", "file": path}))).await;
        assert_eq!(r["isError"], true, "{r}");
        assert!(text(&r).contains(want), "{want}: {r}");
    }
    // A FIFO is refused at once, never waited on for a writer.
    #[cfg(unix)]
    {
        let fifo = dir.path().join("fifo");
        let c = std::ffi::CString::new(fifo.to_str().unwrap()).unwrap();
        // SAFETY: c is a valid NUL-terminated path.
        assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
        let err = send::read_message_file(fifo.to_str().unwrap()).unwrap_err();
        assert!(err.contains("not a regular file"), "{err}");
    }
    // Another user's file is refused even when readable.
    #[cfg(unix)]
    {
        // SAFETY: geteuid has no preconditions.
        if unsafe { libc::geteuid() } != 0 {
            let err = send::read_message_file("/etc/passwd").unwrap_err();
            assert!(err.contains("not your file"), "{err}");
        }
    }
    let both = json!({"to": "file-lane", "text": "x", "file": brief});
    let r = call(&client, &tool("send", both)).await;
    assert_eq!(text(&r), "give text or file, not both", "{r}");
}

/// Past both the old 256 KiB file refusal and the 31 MiB RPC envelope: the agent
/// receives the complete file by reference, through the same durable outbox.
#[tokio::test]
async fn a_large_message_file_is_uploaded_and_reaches_the_agent_intact() {
    large_message_arrives(true, false).await;
}

#[tokio::test]
async fn text_past_the_rpc_envelope_reaches_the_agent_intact() {
    large_message_arrives(false, false).await;
}

#[tokio::test]
async fn a_large_notice_keeps_its_metadata_and_complete_body() {
    large_message_arrives(true, true).await;
    large_message_arrives(false, true).await;
}

#[test]
fn json_expansion_is_counted_before_deciding_to_upload_text() {
    let plain = "a".repeat(6 << 20);
    assert!(!send::text_needs_file(&plain));
    let escaped = "\0".repeat(6 << 20);
    assert!(send::text_needs_file(&escaped));
}

async fn large_message_arrives(from_file: bool, notice: bool) {
    use sha2::Digest;
    use std::io::{Read, Write};
    let (hub, client, _socket) = daemon().await;
    let lane = session(&client, "large-file-lane").await;
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("instructions.md");
    let chunk = b"Read every part of these instructions.\n".repeat(2048);
    let mut expected = sha2::Sha256::new();
    {
        let mut file = std::fs::File::create(&path).unwrap();
        for _ in 0..540 {
            file.write_all(&chunk).unwrap();
            expected.update(&chunk);
        }
    }
    assert!(std::fs::metadata(&path).unwrap().len() > 40 << 20);
    let mut args = if from_file {
        json!({"to": "large-file-lane", "file": path})
    } else {
        json!({"to": "large-file-lane", "text": std::fs::read_to_string(&path).unwrap()})
    };
    if notice {
        args.set(
            "notice",
            json!({"sender": "audit", "host": "test", "severity": "warn", "title": "large brief"}),
        );
    }
    let name = if from_file { "instructions.md" } else { "message.txt" };
    let started = std::time::Instant::now();
    let r = call(&client, &tool("send", args)).await;
    assert_eq!(r["isError"], false, "{r}");
    eprintln!(
        "41.133 MiB MCP message (from_file={from_file}) delivered in {:?}",
        started.elapsed()
    );
    assert!(received(&hub, &lane, name).await, "file was not recorded");
    if notice {
        let events = hub.events(&lane, 0, 1000).unwrap();
        let message = events
            .iter()
            .find(|e| e.kind == "user_message" && e.msg.to_string().contains("large brief"))
            .expect("notice message");
        let provenance = &message.msg["_meta"]["provenance"];
        assert_eq!(provenance["kind"], "notice", "{}", message.msg);
        assert_eq!(provenance["notice"]["severity"], "warn", "{}", message.msg);
        assert!(message.msg.to_string().contains("[notice from audit on test · WARN] large brief"));
    }
    let finished = client
        .request(
            method::MUX_WAIT,
            json!({"sessions": [lane], "until": ["ready"], "timeoutMs": 20000}),
        )
        .await
        .unwrap();
    assert_eq!(finished["timedOut"], false, "{finished}");
    let reply = last_replies(&client, &lane, 1).await.unwrap().pop().unwrap();
    // The fake agent prints resource_link:name:mime:file:///path.
    let uri = reply
        .split_whitespace()
        .find_map(|word| {
            word.strip_prefix("resource_link:")?
                .split_once(":file://")
                .map(|(_, path)| format!("file://{path}"))
        })
        .unwrap_or_else(|| panic!("agent got no file reference: {reply}"));
    let saved = reqwest::Url::parse(&uri).unwrap().to_file_path().unwrap();
    assert_eq!(saved.file_name().unwrap(), name);
    let mut file = std::fs::File::open(saved).unwrap();
    let mut actual = sha2::Sha256::new();
    let mut bytes = [0u8; 65536];
    loop {
        let n = file.read(&mut bytes).unwrap();
        if n == 0 {
            break;
        }
        actual.update(bytes.get(..n).unwrap());
    }
    assert_eq!(actual.finalize(), expected.finalize());
}

/// `supersede`: a second message under the same key replaces the first while it still waits.
/// A gated turn holds the queue (no timing): it ends only when the test opens its FIFO.
#[cfg(unix)]
#[tokio::test]
async fn supersede_replaces_your_queued_message() {
    let (hub, client, _dir) = daemon().await;
    let lane = session(&client, "sup-lane").await;
    let dir = tempfile::tempdir().unwrap();
    let fifo = dir.path().join("gate");
    let c = std::ffi::CString::new(fifo.to_str().unwrap()).unwrap();
    // SAFETY: c is a valid NUL-terminated path.
    assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
    let gate =
        json!({"to": "sup-lane", "text": format!("gate: {}", fifo.display()), "steer": false});
    let r = call(&client, &tool("send", gate)).await;
    assert_eq!(r["structuredContent"]["delivery"], "started", "{r}");
    let order = json!({"to": "sup-lane", "text": "order", "steer": false, "supersede": "cause-1"});
    let first = call(&client, &tool("send", order)).await;
    assert_eq!(first["structuredContent"]["delivery"], "queued", "{first}");
    assert_eq!(first["structuredContent"]["replaced"], 0, "{first}");
    let fix = json!({"messages": [{"to": "sup-lane", "text": "correction", "steer": false, "supersede": "cause-1"}]});
    let second = call(&client, &tool("send", fix)).await;
    let row = &second["structuredContent"]["results"][0];
    assert_eq!(row["delivery"], "queued", "{second}");
    assert_eq!(row["replaced"], 1, "{second}");
    assert_eq!(
        row["replacedPromptIds"],
        json!([first["structuredContent"]["promptId"]]),
        "{second}"
    );
    let removed: Vec<Value> = hub
        .events(&lane, 0, 1000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "queue_removed")
        .map(|e| e.msg)
        .collect();
    assert_eq!(removed.len(), 1, "{removed:?}");
    assert_eq!(removed[0]["reason"], "superseded");
    // The gated turn ends; the correction runs, the order never does.
    tokio::task::spawn_blocking(move || std::fs::write(fifo, b"go")).await.unwrap().unwrap();
    assert!(received(&hub, &lane, "correction").await, "the correction never ran");
}

fn target(index: usize, to: &str, key: &str) -> send::Target {
    send::Target {
        index,
        to: to.to_owned(),
        key: key.to_owned(),
        tag: None,
        text: "x".to_owned(),
        file: None,
        item: send::Item::default(),
    }
}

/// Targets that share any alias, directly or through another, form one chain, in order.
#[test]
fn messages_to_one_session_form_one_chain() {
    let aliases: Vec<Vec<String>> = [
        vec!["lane-a", "id-a"],
        vec!["lane-b", "id-b"],
        vec!["id-a"],
        vec!["nobody", "\0unresolved"],
        vec!["huge-blue/id-c", "huge-blue/lane-c"],
        vec!["ghost", "\0unresolved"],
        // Joins lane-b's chain through x, which only it and seat 1's later alias share.
        vec!["x"],
        vec!["x", "id-b"],
    ]
    .into_iter()
    .map(|names| names.into_iter().map(str::to_owned).collect())
    .collect();
    assert_eq!(send::same_session(&aliases), vec![vec![0, 2], vec![1, 6, 7], vec![3, 5], vec![4]]);
}

/// Codex review: a session named by its name in one item and by its id in another is one
/// session, so its messages are one chain; a tag's target is its id already.
#[tokio::test]
async fn one_session_by_name_and_by_id_is_one_chain() {
    let (_hub, client, _dir) = daemon().await;
    let a = session(&client, "ident-a").await;
    session(&client, "ident-b").await;
    let mut by_tag = target(3, "ident-a", &a);
    by_tag.tag = Some("area=x".to_owned());
    let targets = [
        target(0, "ident-a", "ident-a"),
        target(1, &a, &a),
        target(2, "ident-b", "ident-b"),
        by_tag,
        target(4, "nobody", "nobody"),
    ];
    let aliases = send::aliases(&client, &targets).await;
    assert!(aliases[0].contains(&a), "{aliases:?}");
    assert_eq!(send::same_session(&aliases), vec![vec![0, 1, 3], vec![2], vec![4]]);
}

/// Codex review: a peer that is down answers no lookup, so a session there named `peer/id`
/// resolves to nothing, while a tag's target for the same session (from the cached list) is
/// `peer/id` too. Its identical key keeps them one chain, and any other target on that peer
/// joins it, since an unresolved name there could be any of them.
#[tokio::test]
async fn an_unresolved_peer_session_stays_in_one_chain_with_its_tag_target() {
    let (_hub, client, _dir) = daemon().await;
    session(&client, "here").await;
    let mut tagged = target(1, "down-host/lane-p", "down-host/id-p");
    tagged.tag = Some("area=x".to_owned());
    let mut other = target(2, "down-host/lane-q", "down-host/id-q");
    other.tag = Some("area=x".to_owned());
    let targets =
        [target(0, "down-host/id-p", "down-host/id-p"), tagged, other, target(3, "here", "here")];
    let aliases = send::aliases(&client, &targets).await;
    assert_eq!(send::same_session(&aliases), vec![vec![0, 1, 2], vec![3]], "{aliases:?}");
    // A healthy batch's tag targets on one host stay side by side.
    let mut q = target(0, "down-host/lane-q", "down-host/id-q");
    q.tag = Some("t".to_owned());
    let mut p = target(1, "down-host/lane-p", "down-host/id-p");
    p.tag = Some("t".to_owned());
    let aliases = send::aliases(&client, &[q, p]).await;
    assert_eq!(send::same_session(&aliases), vec![vec![0], vec![1]], "{aliases:?}");
}

/// Codex review: the outbox runs every delivery on its own and retries it, so a message queued
/// while the one before it to the same session is still on its way could arrive first. Here the
/// first delivery settles late: the second is not queued until it did. One still on its way at
/// the deadline stops the rest of its chain, each row saying why.
#[tokio::test]
async fn a_message_waits_for_the_one_before_it_to_the_same_session() {
    let targets = [
        target(0, "lane-a", "lane-a"),
        target(1, "lane-a", "lane-a"),
        target(2, "lane-a", "lane-a"),
    ];
    let log = std::sync::Mutex::new(Vec::new());
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    let rows = send::in_order(&targets, vec![0, 1, 2], deadline, |t, wait| {
        let log = &log;
        async move {
            log.lock().unwrap().push(format!("queue {}", t.index));
            assert!(wait <= Duration::from_secs(5));
            // The first is slow to settle, then delivered; the second stays on its way.
            if t.index == 0 {
                tokio::time::sleep(Duration::from_millis(300)).await;
            }
            log.lock().unwrap().push(format!("settled {}", t.index));
            let status = if t.index == 0 { "delivered" } else { "queued" };
            json!({"index": t.index, "to": t.to, "ok": true, "status": status,
                "deliveryId": format!("d{}", t.index)})
        }
    })
    .await;
    assert_eq!(*log.lock().unwrap(), ["queue 0", "settled 0", "queue 1", "settled 1"]);
    assert_eq!(rows.len(), 3);
    assert_eq!(rows[2].0, 2);
    assert_eq!(rows[2].1["ok"], false, "{:?}", rows[2]);
    let why = rows[2].1["error"].as_str().unwrap();
    assert!(why.contains("delivery d1") && why.contains("still on its way"), "{why}");
    // A refusal settles too: the next one still goes.
    let refused = send::in_order(&targets, vec![0, 1], deadline, |t, _| {
        let status = if t.index == 0 { "failed" } else { "delivered" };
        let row = json!({"index": t.index, "ok": t.index != 0, "status": status});
        async move { row }
    })
    .await;
    assert_eq!(refused[1].1["status"], "delivered");
}

/// A batch of two to one live session: both arrive, in the order given.
#[tokio::test]
async fn two_messages_to_one_session_arrive_in_order() {
    let (hub, client, _dir) = daemon().await;
    let lane = session(&client, "order-lane").await;
    let args = json!({"steer": false, "messages": [
        {"to": "order-lane", "text": "one-first"}, {"to": "order-lane", "text": "two-second"}
    ]});
    let r = call(&client, &tool("send", args)).await;
    assert_eq!(r["structuredContent"]["sent"], 2, "{r}");
    assert!(received(&hub, &lane, "two-second").await);
    let texts: Vec<String> = hub
        .events(&lane, 0, 1000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "user_message")
        .map(|e| e.msg.to_string())
        .collect();
    let first = texts.iter().position(|t| t.contains("one-first")).unwrap();
    let second = texts.iter().position(|t| t.contains("two-second")).unwrap();
    assert!(first < second, "{texts:?}");
}

/// `tag`: every live session carrying it, expanded into one row each; none is an error row.
#[tokio::test]
async fn a_tag_expands_to_every_live_session_carrying_it() {
    let (hub, client, _dir) = daemon().await;
    let tagged = |name: &str, area: &str| {
        let client = client.clone();
        let (name, area) = (name.to_owned(), area.to_owned());
        async move {
            let s = client
                .request(
                    method::SESSION_NEW,
                    json!({"cwd": std::env::temp_dir(), "mcpServers": [],
                        "_meta": {"acpmux": {"name": name, "tags": {"area": area}}}}),
                )
                .await
                .unwrap();
            s["sessionId"].as_str().unwrap().to_owned()
        }
    };
    let x = tagged("tag-x", "acpmux").await;
    let y = tagged("tag-y", "acpmux").await;
    tagged("tag-z", "cloud").await;
    let r = call(&client, &tool("send", json!({"tag": "area=acpmux", "text": "all hands"}))).await;
    assert_eq!(r["isError"], false, "{r}");
    let rows = r["structuredContent"]["results"].as_array().unwrap();
    let mut names: Vec<&str> = rows.iter().map(|r| r["to"].as_str().unwrap()).collect();
    names.sort_unstable();
    assert_eq!(names, ["tag-x", "tag-y"], "{r}");
    assert!(rows.iter().all(|r| r["ok"] == true && r["tag"] == "area=acpmux"), "{r}");
    assert!(received(&hub, &x, "all hands").await);
    assert!(received(&hub, &y, "all hands").await);
    let r = call(
        &client,
        &tool(
            "send",
            json!({"messages": [
                {"tag": "area=nowhere", "text": "x"}, {"to": "tag-z", "text": "just you"}
            ]}),
        ),
    )
    .await;
    let rows = r["structuredContent"]["results"].as_array().unwrap();
    assert_eq!(rows[0]["ok"], false, "{r}");
    assert!(rows[0]["error"].as_str().unwrap().contains("no live session carries"), "{r}");
    assert_eq!(rows[1]["ok"], true, "{r}");
}

#[tokio::test]
async fn send_delivers_to_the_named_session_and_returns_its_prompt_id() {
    let (hub, client, _dir) = daemon().await;
    let lane = session(&client, "lane-a").await;
    let r = call(&client, &tool("send", json!({"to": "lane-a", "text": "rebase on main"}))).await;
    assert_eq!(r["isError"], false, "{r}");
    let prompt_id = r["structuredContent"]["promptId"].as_str().unwrap().to_owned();
    assert_eq!(r["structuredContent"]["sessionId"], json!(lane), "{r}");
    assert!(text(&r).starts_with("Sent to lane-a:"), "{r}");
    assert!(text(&r).contains(&prompt_id), "{r}");
    // The message reached the lane's agent.
    let mut seen = false;
    for _ in 0..100 {
        let events = hub.events(&lane, 0, 1000).unwrap();
        if events
            .iter()
            .any(|e| e.kind == "user_message" && e.msg.to_string().contains("rebase on main"))
        {
            seen = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(seen, "the lane never got the message");
}

/// Codex review: a send goes through this daemon's outbox (`_acpmux/send_queue`), as
/// `acpmux send --no-wait` does, so a peer that is down or a slow target is retried and survives a
/// restart; the result names the delivery, and `send_status` knows it.
#[tokio::test]
async fn send_goes_through_the_outbox_and_names_its_delivery() {
    let (_hub, client, _dir) = daemon().await;
    session(&client, "lane-c").await;
    let r = call(&client, &tool("send", json!({"to": "lane-c", "text": "status?"}))).await;
    assert_eq!(r["isError"], false, "{r}");
    let delivery = r["structuredContent"]["deliveryId"].as_str().unwrap_or_default().to_owned();
    assert!(!delivery.is_empty(), "no delivery id: {r}");
    let status = client
        .request(method::MUX_SEND_STATUS, json!({"deliveryId": delivery, "waitMs": 5000}))
        .await
        .unwrap();
    assert_eq!(status["status"], "delivered", "{status}");
    assert_eq!(status["promptId"], r["structuredContent"]["promptId"], "{status} {r}");
}

/// `class` (`prompt_class.rs`) goes with the message; a class that is not one of the four is
/// this call's error, sent nowhere.
#[tokio::test]
async fn send_carries_its_class_and_refuses_any_other() {
    let (_hub, client, _dir) = daemon().await;
    session(&client, "lane-d").await;
    let bad = json!({"to": "lane-d", "text": "x", "class": "urgent"});
    let r = call(&client, &tool("send", bad)).await;
    assert_eq!(r["isError"], true, "{r}");
    assert!(text(&r).contains("class must be one of"), "{r}");
    let block = json!({"to": "lane-d", "text": "stuck on review", "class": "block"});
    let r = call(&client, &tool("send", block)).await;
    assert_eq!(r["isError"], false, "{r}");
    assert_eq!(send_class(&json!({"class": "fyi"})), Ok(Some("fyi".to_owned())));
    assert_eq!(send_class(&json!({})), Ok(None));
    assert!(send_class(&json!({"class": 2})).is_err());
    let schema = &tools()[0]["inputSchema"]["properties"]["class"]["enum"];
    assert_eq!(schema, &json!(["block", "question", "result", "fyi", "blocker", "action"]));
}

#[tokio::test]
async fn ls_last_and_info_read_the_sessions() {
    let (_hub, client, _dir) = daemon().await;
    let lane = session(&client, "lane-b").await;
    let r = call(&client, &tool("last", json!({"name": "lane-b"}))).await;
    assert_eq!(text(&r), "lane-b has not replied yet.", "{r}");
    let prompt = PromptId::new(None);
    crate::cli::output::collect_reply(
        client.clone(),
        &lane,
        "hello",
        crate::cli::output::CollectOpts {
            deadline: None,
            timeout: Some(20),
            on_permission: crate::cli::output::OnPermission::Fail,
            stall_secs: 30,
            retries: 0,
            steer: false,
        },
        &prompt,
    )
    .await
    .unwrap();
    let r = call(&client, &tool("last", json!({"name": "lane-b"}))).await;
    assert_eq!(text(&r), "echo: hello", "{r}");
    let r = call(&client, &tool("ls", json!({}))).await;
    assert!(text(&r).lines().any(|l| l.starts_with("lane-b  [")), "{r}");
    let r = call(&client, &tool("info", json!({"name": "lane-b"}))).await;
    assert_eq!(r["structuredContent"]["sessionId"], json!(lane), "{r}");
    // `search` reads the named session, or this server's own chat when none is named.
    let r = search_tool(&client, "", &json!({"query": "HELLO echo", "name": "lane-b"})).await;
    assert_eq!(r["isError"], false, "{r}");
    assert!(text(&r).ends_with("(assistant): echo: hello"), "{r}");
    let r = search_tool(&client, &lane, &json!({"query": "hello", "role": "user"})).await;
    let hits = r["structuredContent"]["hits"].as_array().unwrap();
    assert_eq!(hits.len(), 1, "{r}");
    assert_eq!(hits[0]["snippet"], "hello", "{r}");
    let r = search_tool(&client, "", &json!({"query": "hello"})).await;
    assert_eq!(r["isError"], true, "no chat and no name: {r}");
}

/// A fleet-sized list (thousands of closed sessions, each row carrying its last prompt and
/// receipts) answers in a reply small enough for any harness's MCP pipe: live sessions only by
/// default, newest first, slim rows, a cap that says how many more there are. The whole list
/// once came to 29 MB and every `acpmux_ls` call in a Chief turn ended in "Connection closed".
#[test]
fn a_fleet_sized_list_answers_small_and_live_first() {
    let big = "x".repeat(4000);
    let mut sessions: Vec<Value> = (0..3000)
        .map(|i| {
            json!({"name": format!("old-{i}"), "status": "closed", "title": "done", "peer": "peer-a",
                "sessionId": format!("c{i}"), "updatedAt": i, "lastPrompt": big, "sessionReceipt": big})
        })
        .collect();
    for i in 0..300 {
        sessions.push(
            json!({"name": format!("lane-{i}"), "status": if i % 2 == 0 {"idle"} else {"running"},
            "title": format!("Lane {i}"), "sessionId": format!("l{i}"), "updatedAt": 10_000 + i,
            "lastPrompt": big, "lastTurn": big, "enforcement": {"detail": big}}),
        );
    }
    let all = json!({"sessions": sessions});

    let r = ls_result(&all, &json!({}));
    let size = r.to_string().len();
    assert!(size < 64 * 1024, "reply is {size} bytes");
    let rows = r["structuredContent"]["sessions"].as_array().unwrap();
    assert_eq!(rows.len(), LS_DEFAULT_LIMIT, "{}", text(&r));
    assert!(rows.iter().all(|s| s["status"] != "closed"), "closed rows by default");
    assert!(rows[0].get("lastPrompt").is_none(), "rows are slim: {}", rows[0]);
    assert_eq!(rows[0]["name"], "lane-299", "newest first");
    assert_eq!(r["structuredContent"]["more"], json!(300 - LS_DEFAULT_LIMIT));
    assert!(text(&r).lines().last().unwrap().contains("more"), "{}", text(&r));

    // query narrows by name or title; status=closed still reaches the closed ones.
    let r = ls_result(&all, &json!({"query": "LANE 7"}));
    let names: Vec<&str> = r["structuredContent"]["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|s| s["name"].as_str())
        .collect();
    assert!(
        names.contains(&"lane-7") && names.iter().all(|n| n.starts_with("lane-7")),
        "{names:?}"
    );
    let r = ls_result(&all, &json!({"status": "closed", "limit": 5}));
    assert_eq!(r["structuredContent"]["sessions"].as_array().unwrap().len(), 5);
    assert!(text(&r).starts_with("peer-a/old-2999  [closed]"), "{}", text(&r));
    assert!(text(&r).contains("raise limit (up to 500)"), "{}", text(&r));

    // A closed session is found by query once status asks for closed ones, and only then.
    let r = ls_result(&all, &json!({"query": "old-42", "status": "closed"}));
    assert!(text(&r).lines().any(|l| l.starts_with("peer-a/old-42  [closed]")), "{}", text(&r));
    let r = ls_result(&all, &json!({"query": "old-42"}));
    assert_eq!(text(&r), "No sessions.", "{r}");
}

#[tokio::test]
async fn an_unknown_session_or_a_missing_argument_is_an_error_the_agent_reads() {
    let (_hub, client, _dir) = daemon().await;
    let r = call(&client, &tool("send", json!({"to": "nobody", "text": "hi"}))).await;
    assert_eq!(r["isError"], true, "{r}");
    let r = call(&client, &tool("send", json!({"to": "nobody"}))).await;
    assert_eq!(r["isError"], true, "{r}");
    assert_eq!(text(&r), "to and text are required", "{r}");
    let r = call(&client, &tool("nope", json!({}))).await;
    assert_eq!(text(&r), "unknown tool: nope", "{r}");
    // A typo of a real tool names the tool it was likely meant to be.
    let r = call(&client, &tool("team_sned", json!({}))).await;
    assert_eq!(r["isError"], true, "{r}");
    assert_eq!(text(&r), "unknown tool: team_sned; did you mean team_send?", "{r}");
}

/// Arguments that are not an object are an error the agent reads, never a panic.
#[tokio::test]
async fn bg_tools_refuse_arguments_that_are_not_an_object() {
    let (_hub, client, _dir) = daemon().await;
    for name in bg::TOOLS {
        let r = bg::call(&client, "any", name, &json!([])).await;
        assert_eq!(r["isError"], true, "{name}: {r}");
        assert_eq!(text(&r), "arguments must be an object", "{name}: {r}");
    }
}

/// Exercise the actual MCP-to-daemon socket path without substituting an MCP
/// implementation. Any wrong RPC method, argument, lost receipt field or hidden
/// refusal fails independently of the mesh client's tests.
#[cfg(unix)]
#[tokio::test]
async fn team_tools_use_the_shared_rpc_paths_and_preserve_receipts_and_refusals() {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

    let receipt = json!({"messageId": "msg_example", "state": "queued",
        "resolution": {"teamAddress": "@team/reviewer", "sessionId": "resolved-agent"},
        "startWork": "information"});
    let inbox = json!({"messages": [{"messageId": "msg_example", "body": "review ready",
        "from": {"teamAddress": "@member/coordinator"}, "state": "delivered",
        "startWork": "information"}]});
    let acknowledged = json!({"messageId": "msg_example", "state": "acked"});
    let cases = vec![
        (
            "team_send",
            json!({"to": "@team/reviewer", "body": "review ready"}),
            "_acpmux/team/send",
            json!({"to": "@team/reviewer", "body": "review ready"}),
            receipt,
        ),
        ("team_inbox", json!({}), "_acpmux/team/inbox", json!({"unreadOnly": true}), inbox.clone()),
        (
            "team_inbox",
            json!({"unreadOnly": false}),
            "_acpmux/team/inbox",
            json!({"unreadOnly": false}),
            inbox,
        ),
        (
            "team_ack",
            json!({"id": "msg_example"}),
            "_acpmux/team/ack",
            json!({"id": "msg_example"}),
            acknowledged,
        ),
    ];
    let expected = cases
        .iter()
        .map(|(_, _, method, args, result)| (*method, args.clone(), result.clone()))
        .collect::<Vec<_>>();
    let dir = cmux_unix_socket::short_test_dir("acpmux-team-mcp");
    let path = dir.path().join("d.sock");
    let listener = tokio::net::UnixListener::bind(&path).unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let (read, mut write) = stream.into_split();
        let mut lines = BufReader::new(read).lines();
        let mut requests = vec![("initialize", None, json!({}))];
        requests.extend(expected.into_iter().map(|(m, a, r)| (m, Some(a), r)));
        for (method, arguments, result) in requests {
            let request: Value =
                serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
            assert_eq!(request["method"], method, "{request}");
            if let Some(arguments) = arguments {
                assert_eq!(request["params"], arguments, "{request}");
            }
            let response = json!({"jsonrpc": "2.0", "id": request["id"], "result": result});
            write.write_all(format!("{response}\n").as_bytes()).await.unwrap();
        }
        let request: Value =
            serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
        assert_eq!(request["method"], "_acpmux/team/send");
        let response = json!({"jsonrpc": "2.0", "id": request["id"],
            "error": {"code": -32602, "message": "team messaging is off on this daemon"}});
        write.write_all(format!("{response}\n").as_bytes()).await.unwrap();
    });
    let client = Client::connect(&path).await.unwrap();
    for (name, arguments, _, _, expected) in cases {
        let result =
            tokio::time::timeout(Duration::from_secs(5), call(&client, &tool(name, arguments)))
                .await
                .unwrap();
        assert_eq!(result["isError"], false, "{result}");
        assert_eq!(result["structuredContent"], expected, "{result}");
        assert_eq!(serde_json::from_str::<Value>(&text(&result)).unwrap(), expected);
    }
    let result = tokio::time::timeout(
        Duration::from_secs(5),
        call(&client, &tool("team_send", json!({"to": "@team/reviewer", "body": "retry"}))),
    )
    .await
    .unwrap();
    assert_eq!(result["isError"], true, "{result}");
    assert!(text(&result).contains("team messaging is off on this daemon"), "{result}");
    server.await.unwrap();
}

/// A Chief turn's `CMUX_MCP_TOOLS` reaches this server too (`agent_tools::scoped`): standalone,
/// without a `cmux` server to fold into, it lists only the six coordinator tools, never `bg_*` or
/// `team_*` (#30082 review).
#[test]
fn an_allowlist_keeps_only_the_acpmux_tools_it_names() {
    let names = |v: &Value| crate::mcp_hint::names(v).map(str::to_owned).collect::<Vec<_>>();
    let all = tools();
    assert_eq!(names(&allowed(all.clone(), None)), names(&all));
    let chief = allowed(all.clone(), Some(crate::agent_tools::CHIEF_TURN_TOOLS));
    assert_eq!(names(&chief), ["send", "inbox_read", "inbox_reply", "ls", "last", "info"]);
    assert!(names(&allowed(all, Some("render,agents_wait"))).is_empty());
}

/// Every chat's `acpmux` server lists `github_status` and tells the agent when to call it, and a
/// Chief turn's allowlist (which does not name it) leaves it out like any other tool.
#[test]
fn github_status_is_listed_with_its_instruction() {
    let all = tools_with_artifacts(false);
    assert!(crate::mcp_hint::names(&all).any(|n| n == crate::github_status::TOOL));
    let text = instructions(&all).unwrap();
    assert!(text.contains("call github_status"), "{text}");
    assert!(text.contains("bg_start"), "{text}");
    assert!(text.contains("as one batch of independent tool calls"), "{text}");
    let scoped = allowed(all.clone(), Some("acpmux_github_status"));
    assert_eq!(crate::mcp_hint::names(&scoped).collect::<Vec<_>>(), ["github_status"]);
    assert_eq!(instructions(&scoped).unwrap(), crate::github_status::STEER);
    let chief = allowed(all, Some(crate::agent_tools::CHIEF_TURN_TOOLS));
    assert!(!crate::mcp_hint::names(&chief).any(|n| n == crate::github_status::TOOL));
}

/// Every chat's `acpmux` server lists `wrap_up` and tells the agent to end a turn with it; a Chief
/// turn's allowlist leaves it out like any other tool.
#[test]
fn wrap_up_is_listed_with_its_instruction() {
    let all = tools_with_artifacts(false);
    assert!(crate::mcp_hint::names(&all).any(|n| n == "wrap_up"));
    let text = instructions(&all).unwrap();
    assert!(text.contains("call wrap_up as your last step"), "{text}");
    let chief = allowed(all, Some(crate::agent_tools::CHIEF_TURN_TOOLS));
    assert!(!crate::mcp_hint::names(&chief).any(|n| n == "wrap_up"));
}
