//! The memory inspector (inspect/): a turn's prompt laid out again from the
//! trace is byte for byte what the turn sent; nodes and their children agree
//! with the agent's zoom; the HTTP server is loopback only, needs its token,
//! takes GET only, and never writes the memory.

mod common;

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::sync::Arc;

use common::*;
use optchat_chief::inspect::{Inspector, http, turn_prompt};
use optchat_chief::trace::Trace;
use optchat_host::Kind;
use serde_json::Value;

/// A harness with a trace and a memory big enough that the view has cache
/// marks and merged lines (450-byte messages, a 128 KB view).
fn harness(cached: bool, preload: usize) -> Harness {
    let mut h = Harness::new(default_script());
    let traces = h.dir.path().join("traces");
    h.brain.set_trace(Trace::open(&traces, false).unwrap());
    h.agents.inner.lock().unwrap().system_prompts = cached;
    for k in 0..preload {
        let text = format!("note {k}: {}", "context words ".repeat(31));
        h.chat.append(Kind::User, &text).unwrap();
    }
    assert!(h.chat.wait_idle(None, Some(WAIT)), "the compactor settles");
    h.connect();
    h
}

fn inspector(h: &Harness) -> Arc<Inspector> {
    Arc::new(Inspector::new(
        h.chat.clone(),
        h.dir.path().join("traces"),
        h.dir.path().join("state").join("settle.json"),
        optchat_chief::prompt::claude_md(None),
    ))
}

fn starts(h: &Harness) -> Vec<Value> {
    optchat_chief::report::read(&h.dir.path().join("traces"), 0)
        .unwrap()
        .into_iter()
        .filter(|e| e["ev"] == "turn.start")
        .collect()
}

/// The cached layout (Claude harness, a preset system prompt): the system
/// prompt with the view's head and every user block come back exactly.
#[test]
fn view_at_turn_equals_the_bytes_the_turn_sent_cached_layout() {
    let mut h = harness(true, 320);
    h.say("user_local", "first question");
    h.settle();
    for k in 0..20 {
        h.chat
            .append(
                Kind::Talk,
                &format!("later reply {k}: {}", "more ".repeat(90)),
            )
            .unwrap();
    }
    assert!(h.chat.wait_idle(None, Some(WAIT)));
    h.say("user_local", "second question");
    h.settle();
    let starts = starts(&h);
    assert_eq!(starts.len(), 2);
    let agents = h.agents.inner.lock().unwrap();
    for (k, start) in starts.iter().enumerate() {
        let prompt = turn_prompt(&h.chat, start, &optchat_chief::prompt::claude_md(None));
        assert_eq!(prompt.layout, "cached");
        assert!(
            prompt.view_matches && prompt.system_matches && prompt.messages_match,
            "{:?}",
            prompt.note
        );
        assert_eq!(
            prompt.blocks, agents.prompts[k],
            "turn {k}: the user blocks"
        );
        assert_eq!(
            Some(&prompt.system),
            agents.systems[k].as_ref(),
            "turn {k}: the system prompt"
        );
        assert_eq!(
            prompt.system,
            optchat_chief::prompt::claude_md(None),
            "the system prompt is the constant text alone (spec 3.3)"
        );
    }
    assert_ne!(
        starts[0]["view"]["hash"], starts[1]["view"]["hash"],
        "the view moved between the turns"
    );
}

/// The blocks layout (no preset system prompt): view pieces, then the messages.
#[test]
fn view_at_turn_equals_the_bytes_the_turn_sent_blocks_layout() {
    let mut h = harness(false, 200);
    h.say("user_local", "hello there");
    h.settle();
    let start = &starts(&h)[0];
    let prompt = turn_prompt(&h.chat, start, &optchat_chief::prompt::claude_md(None));
    assert_eq!(prompt.layout, "blocks");
    assert!(
        prompt.view_matches && prompt.messages_match,
        "{:?}",
        prompt.note
    );
    assert_eq!(prompt.blocks, h.agents.inner.lock().unwrap().prompts[0]);
    assert_eq!(prompt.messages.len(), 1);
    assert_eq!(prompt.messages[0].2, "hello there");
}

/// Each view line names its node; a node's children are the two lines the
/// agent's zoom answers; one message zooms to the message whole.
#[test]
fn nodes_and_children_agree_with_zoom() {
    let h = harness(true, 320);
    let insp = inspector(&h);
    let now = insp
        .answer("/api/turn", &[("key".into(), "now".into())])
        .unwrap();
    let lines = now["lines"].as_array().unwrap();
    assert_eq!(lines.len(), h.chat.status().view_lines);
    assert!(
        lines.iter().any(|l| l["level"].as_u64().unwrap() > 0),
        "the view has merged lines"
    );
    let view = now["view"]["text"].as_str().unwrap();
    for line in lines {
        let off = line["offset"].as_u64().unwrap() as usize;
        let len = line["bytes"].as_u64().unwrap() as usize;
        assert!(view[off..off + len].starts_with(&format!("{}|", line["name"].as_str().unwrap())));
    }
    let merged = lines
        .iter()
        .find(|l| l["level"].as_u64().unwrap() > 0)
        .unwrap();
    let name = merged["name"].as_str().unwrap();
    let node = insp
        .answer("/api/node", &[("name".into(), name.into())])
        .unwrap();
    let (start, n) = (node["start"].as_u64().unwrap(), node["n"].as_u64().unwrap());
    assert_eq!(
        node["zoom"]["answer"].as_str().unwrap(),
        h.chat.zoom(start, n).unwrap()
    );
    let kids = node["children"].as_array().unwrap();
    assert_eq!(kids[0]["name"], format!("{}+{}", start, n / 2));
    assert_eq!(kids[1]["name"], format!("{}+{}", start + n / 2, n / 2));
    let zoomed: Vec<&str> = node["zoom"]["answer"].as_str().unwrap().lines().collect();
    for (kid, line) in kids.iter().zip(zoomed) {
        assert!(line.starts_with(&format!("{}|", kid["name"].as_str().unwrap())));
        assert!(
            kid["built"].as_bool().unwrap(),
            "a merged line's children are built"
        );
    }
    // Three hops down to one message.
    let mut at = name.to_owned();
    for _ in 0..n.trailing_zeros() {
        let node = insp
            .answer("/api/node", &[("name".into(), at.clone())])
            .unwrap();
        at = node["children"][0]["name"].as_str().unwrap().to_owned();
    }
    let leaf = insp
        .answer("/api/node", &[("name".into(), at.clone())])
        .unwrap();
    assert_eq!(leaf["n"], 1);
    let (_, text) = h.chat.message(start).unwrap();
    assert_eq!(leaf["message"]["text"].as_str().unwrap(), text);
    // A level lists 2^l-message nodes; bad names are refused.
    let level = insp
        .answer("/api/level", &[("l".into(), "1".into())])
        .unwrap();
    assert_eq!(
        level["count"].as_u64().unwrap(),
        h.chat.status().messages / 2
    );
    assert_eq!(
        insp.answer("/api/node", &[("name".into(), "3+2".into())])
            .unwrap_err()
            .0,
        400
    );
    assert_eq!(
        insp.answer("/api/node", &[("name".into(), "0+1048576".into())])
            .unwrap_err()
            .0,
        404
    );
    // date(id) and search answer like the tools.
    let date = insp
        .answer("/api/date", &[("id".into(), "5".into())])
        .unwrap();
    assert_eq!(date["date"].as_str(), h.chat.date(5).as_deref());
    let hits = insp
        .answer("/api/search", &[("q".into(), "note 7:".into())])
        .unwrap();
    assert!(
        hits["hits"]
            .as_array()
            .unwrap()
            .iter()
            .any(|x| x["name"] == "7+1")
    );
}

struct Got {
    status: u16,
    headers: String,
    body: String,
}

fn get(addr: SocketAddr, method: &str, path: &str, host: &str, extra: &str) -> Got {
    let mut s = TcpStream::connect(addr).unwrap();
    write!(s, "{method} {path} HTTP/1.1\r\nHost: {host}\r\n{extra}\r\n").unwrap();
    let mut raw = String::new();
    s.read_to_string(&mut raw).unwrap();
    let (head, body) = raw.split_once("\r\n\r\n").unwrap_or((&raw, ""));
    let status = head.split_whitespace().nth(1).unwrap().parse().unwrap();
    Got {
        status,
        headers: head.to_owned(),
        body: body.to_owned(),
    }
}

/// Loopback only, token or ticket only, GET only.
#[test]
fn the_server_refuses_non_loopback_missing_tokens_and_writes() {
    let h = harness(true, 40);
    let token = http::new_secret().unwrap();
    let wide: SocketAddr = "0.0.0.0:0".parse().unwrap();
    assert!(
        http::start(inspector(&h), wide, token.clone()).is_err(),
        "a non-loopback bind is refused"
    );
    let running =
        http::start(inspector(&h), "127.0.0.1:0".parse().unwrap(), token.clone()).unwrap();
    let addr = running.addr;
    let host = format!("127.0.0.1:{}", addr.port());
    let bearer = format!("Authorization: Bearer {token}\r\n");
    assert_eq!(get(addr, "GET", "/api/status", &host, "").status, 401);
    assert_eq!(
        get(
            addr,
            "GET",
            "/api/status",
            &host,
            "Authorization: Bearer nope\r\n"
        )
        .status,
        401
    );
    let ok = get(addr, "GET", "/api/status", &host, &bearer);
    assert_eq!(ok.status, 200);
    let status: Value = serde_json::from_str(&ok.body).unwrap();
    assert_eq!(status["messages"], 40);
    assert_eq!(
        get(addr, "GET", "/api/status", "evil.example:80", &bearer).status,
        403,
        "DNS rebinding"
    );
    for method in ["POST", "PUT", "DELETE", "PATCH"] {
        assert_eq!(
            get(addr, method, "/api/status", &host, &bearer).status,
            405,
            "{method}"
        );
    }
    assert!(!running.url().contains(&token), "no secret in the URL");
    // The page: a one-time ticket buys a cookie session.
    assert_eq!(get(addr, "GET", "/", &host, "").status, 401);
    assert_eq!(get(addr, "GET", "/api/ticket", &host, "").status, 401);
    let ticket: Value =
        serde_json::from_str(&get(addr, "GET", "/api/ticket", &host, &bearer).body).unwrap();
    let ticket = ticket["ticket"].as_str().unwrap();
    let probe = get(addr, "HEAD", &format!("/?ticket={ticket}"), &host, "");
    assert_eq!(probe.status, 401, "a HEAD does not spend the ticket");
    let spent = get(addr, "GET", &format!("/?ticket={ticket}"), &host, "");
    assert_eq!(spent.status, 303);
    assert!(
        spent
            .headers
            .contains(&format!("optchat_inspector_{}=", addr.port())),
        "the cookie is per port"
    );
    let cookie = spent
        .headers
        .lines()
        .find_map(|l| l.strip_prefix("Set-Cookie: "))
        .unwrap()
        .split(';')
        .next()
        .unwrap()
        .to_owned();
    assert!(spent.headers.contains("HttpOnly") && spent.headers.contains("SameSite=Strict"));
    // The browser loads the ticket URL again when the tab moves into its
    // column: within 10 s that reload gets the same session, not a new one.
    let again = get(addr, "GET", &format!("/?ticket={ticket}"), &host, "");
    assert_eq!(again.status, 303);
    assert!(again.headers.contains(&cookie), "the same session");
    // A ticket nobody minted buys nothing.
    assert_eq!(
        get(
            addr,
            "GET",
            &format!("/?ticket={}", "0".repeat(64)),
            &host,
            ""
        )
        .status,
        401
    );
    let page = get(addr, "GET", "/", &host, &format!("Cookie: {cookie}\r\n"));
    assert_eq!(page.status, 200);
    assert!(page.headers.contains("Content-Security-Policy"));
    assert_eq!(
        get(
            addr,
            "GET",
            "/api/status",
            &host,
            &format!("Cookie: {cookie}\r\n")
        )
        .status,
        200
    );
}

/// Every endpoint, called on a quiet memory, leaves the database as it was.
#[test]
fn the_api_never_writes_the_memory() {
    let mut h = harness(true, 120);
    h.say("user_local", "a question");
    h.settle();
    assert!(h.chat.wait_idle(None, Some(WAIT)));
    let db = h.chat.db_path();
    let wal = db.with_extension("sqlite3-wal");
    let before = (
        std::fs::read(&db).unwrap(),
        std::fs::metadata(&wal).map(|m| m.len()).ok(),
        h.chat.status(),
    );
    let insp = inspector(&h);
    let key = starts(&h)[0]["turn"].as_str().unwrap().to_owned();
    let q = |k: &str, v: &str| vec![(k.to_owned(), v.to_owned())];
    for (path, query) in [
        ("/api/status", vec![]),
        ("/api/turns", vec![]),
        ("/api/turn", q("key", &key)),
        ("/api/turn", q("key", "now")),
        ("/api/node", q("name", "0+64")),
        ("/api/level", q("l", "2")),
        ("/api/date", q("id", "3")),
        ("/api/search", q("q", "context")),
    ] {
        insp.answer(path, &query)
            .unwrap_or_else(|e| panic!("{path}: {e:?}"));
    }
    let after = (
        std::fs::read(&db).unwrap(),
        std::fs::metadata(&wal).map(|m| m.len()).ok(),
        h.chat.status(),
    );
    assert!(before.0 == after.0, "the database file is unchanged");
    assert_eq!(before.1, after.1, "the WAL did not grow");
    assert_eq!(before.2, after.2);
}

/// After its reload window a spent ticket buys nothing.
#[test]
fn a_spent_ticket_expires() {
    let h = harness(true, 10);
    let token = http::new_secret().unwrap();
    let running =
        http::start(inspector(&h), "127.0.0.1:0".parse().unwrap(), token.clone()).unwrap();
    let addr = running.addr;
    let host = format!("127.0.0.1:{}", addr.port());
    let bearer = format!("Authorization: Bearer {token}\r\n");
    let ticket: Value =
        serde_json::from_str(&get(addr, "GET", "/api/ticket", &host, &bearer).body).unwrap();
    let url = format!("/?ticket={}", ticket["ticket"].as_str().unwrap());
    assert_eq!(get(addr, "GET", &url, &host, "").status, 303);
    std::thread::sleep(std::time::Duration::from_secs(11));
    assert_eq!(get(addr, "GET", &url, &host, "").status, 401);
}
