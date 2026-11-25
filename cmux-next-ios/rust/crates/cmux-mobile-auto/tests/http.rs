//! The store's owner routes as HTTP requests: what the phone sends, and how it reads answers.

mod support;

use std::collections::VecDeque;
use std::sync::Mutex;

use cmux_auto_session::cloud::AutoCloud;
use cmux_auto_session::wire::{
    CreateRequest, ErrorCode, Fence, FirstMessage, Holder, InboxPost, LeaseRequest, MachineSetting, Repo,
};
use cmux_mobile_auto::chat::ChatSession;
use cmux_mobile_auto::http::{HttpAutoCloud, HttpReply, HttpRequest, HttpTransport};
use cmux_mobile_auto::rows::{self, Place};
use serde_json::{Value, json};
use support::ready;

/// A transport that answers what it was told to, in order, and keeps what it was asked.
#[derive(Default)]
struct Scripted {
    asked: Mutex<Vec<HttpRequest>>,
    answers: Mutex<VecDeque<Result<HttpReply, String>>>,
}

impl Scripted {
    fn answer(&self, status: u16, body: Value) {
        self.answers.lock().expect("answers").push_back(Ok(HttpReply { status, body: body.to_string() }));
    }

    fn fail(&self, why: &str) {
        self.answers.lock().expect("answers").push_back(Err(why.to_owned()));
    }

    /// Every request so far, as `METHOD path`.
    fn asked(&self) -> Vec<String> {
        let asked = self.asked.lock().expect("asked");
        asked.iter().map(|request| format!("{} {}", request.method, request.path)).collect()
    }

    fn last(&self) -> HttpRequest {
        self.asked.lock().expect("asked").last().cloned().expect("a request")
    }
}

impl HttpTransport for &Scripted {
    async fn send(&self, request: HttpRequest) -> Result<HttpReply, String> {
        self.asked.lock().expect("asked").push(request);
        self.answers
            .lock()
            .expect("answers")
            .pop_front()
            .unwrap_or_else(|| Err("nothing scripted".to_owned()))
    }
}

/// The store's view of a chat, as JSON.
fn session(id: &str, state: &str, last_seq: u64, version: u64) -> Value {
    json!({
        "id": id, "title": "Fix the build", "harness": "claude", "team": null, "owner": "user_1",
        "auto": true, "keepInCloud": false, "holder": "vm:vm_1", "epoch": 2, "state": state, "blocked": null,
        "needsRun": true, "standby": [], "lastSeq": last_seq, "snapshot": 1, "inbox": 0, "inboxAcked": 0,
        "repo": { "remote": "https://example.com/app.git", "branch": "main" },
        "version": version, "createdAt": 10, "updatedAt": 20, "leaseExpiresAt": 0,
        "aFieldANewerStoreAdds": true,
    })
}

#[test]
fn the_list_is_read_with_the_stores_cursor() {
    let http = Scripted::default();
    http.answer(200, json!({ "sessions": [session("as_1", "cloud", 3, 7)], "nextCursor": "eyJ+/=" }));
    http.answer(200, json!({ "sessions": [session("as_2", "resuming", 0, 1)], "nextCursor": null }));
    let cloud = HttpAutoCloud::new(&http);

    let list = ready(rows::list(&cloud)).expect("the list");
    assert_eq!(
        http.asked(),
        ["GET /v1/auto-sessions?limit=100", "GET /v1/auto-sessions?limit=100&cursor=eyJ%2B%2F%3D"]
    );
    let places: Vec<(&str, Place)> = list.chats.iter().map(|chat| (chat.id.as_str(), chat.place)).collect();
    assert_eq!(places, [("as_1", Place::Cloud), ("as_2", Place::Resuming)]);
    assert_eq!(http.last().body, None);
}

#[test]
fn a_chat_is_opened_waited_on_and_sent_to() {
    let http = Scripted::default();
    let cloud = HttpAutoCloud::new(&http);
    let chat = ChatSession::new(cloud, "as_1");
    let record = json!({ "sessionId": "x", "seq": 1, "at": 5, "dir": "mux", "kind": "turn_started", "msg": { "turnId": "t1" } });

    http.answer(200, json!({ "session": session("as_1", "cloud", 1, 7) }));
    http.answer(200, json!({ "events": [{ "seq": 1, "record": record }], "lastSeq": 1 }));
    let opened = ready(chat.open()).expect("opened");
    assert_eq!(opened.records.len(), 1);
    assert_eq!(http.asked(), ["GET /v1/auto-sessions/as_1", "GET /v1/auto-sessions/as_1/events?after=0"]);

    // The held request names the version the phone has, and may take longer than the hold.
    http.answer(200, json!({ "session": session("as_1", "cloud", 1, 7) }));
    let waited = ready(chat.next()).expect("the deadline");
    assert!(waited.records.is_empty());
    let wait = http.last();
    assert_eq!(wait.path, "/v1/auto-sessions/as_1/wait?after=7&timeoutMs=25000");
    assert_eq!(wait.timeout_ms, 35_000);

    http.answer(200, json!({ "state": "delivered", "session": session("as_1", "cloud", 1, 8) }));
    ready(chat.send("m-1", "and \"this\"")).expect("sent");
    let sent = http.last();
    assert_eq!((sent.method, sent.path.as_str()), ("POST", "/v1/auto-sessions/as_1/inbox"));
    let body: Value = serde_json::from_str(&sent.body.expect("a body")).expect("JSON");
    assert_eq!(body, json!({ "id": "m-1", "text": "and \"this\"" }));

    http.answer(200, json!({ "session": session("as_1", "cloud", 1, 9) }));
    ready(chat.keep(true)).expect("kept");
    let kept = http.last();
    assert_eq!(kept.path, "/v1/auto-sessions/as_1/keep");
    assert_eq!(kept.body.as_deref(), Some(r#"{"keepInCloud":true}"#));
}

#[test]
fn a_chat_is_started_and_the_machine_is_read() {
    let http = Scripted::default();
    let cloud = HttpAutoCloud::new(&http);
    http.answer(201, json!({ "session": session("as_9", "resuming", 0, 1) }));
    let request = CreateRequest {
        title: None,
        harness: "claude".into(),
        repo: Repo { remote: "https://example.com/app.git".into(), branch: "main".into() },
        first_message: FirstMessage { id: "m-1".into(), text: "go".into() },
    };
    assert_eq!(ready(cloud.create(&request)).expect("created").id, "as_9");
    let sent = http.last();
    assert_eq!((sent.method, sent.path.as_str()), ("POST", "/v1/auto-sessions"));
    let body: Value = serde_json::from_str(&sent.body.expect("a body")).expect("JSON");
    assert_eq!(
        body,
        json!({ "harness": "claude", "repo": { "remote": "https://example.com/app.git", "branch": "main" },
                "firstMessage": { "id": "m-1", "text": "go" } })
    );

    http.answer(200, json!({ "team": "team_1", "machine": "vm_1" }));
    assert_eq!(ready(cloud.machine()).expect("the machine").machine, "vm_1");
    assert_eq!(http.last().path, "/v1/auto-sessions/machine");
}

#[test]
fn a_refusal_keeps_its_code_and_no_answer_is_retryable() {
    let http = Scripted::default();
    let cloud = HttpAutoCloud::new(&http);

    http.answer(404, json!({ "error": { "code": "auto.no_machine", "message": "no Auto machine is set" } }));
    let error = ready(cloud.machine()).expect_err("no machine");
    assert_eq!(
        (error.code(), error.status(), error.retryable()),
        (Some(ErrorCode::NoMachine), Some(404), false)
    );

    // The store is not there yet (production before Auto ships): a plain 404, not a code of Auto's.
    http.answer(404, json!({ "error": { "code": "not_found", "message": "not found" } }));
    let error = ready(cloud.list(None, None)).expect_err("not found");
    assert_eq!((error.code(), error.status(), error.retryable()), (None, Some(404), false));

    http.answer(503, json!({ "error": { "code": "auto.unavailable", "message": "retry" } }));
    assert!(ready(cloud.get("as_1")).expect_err("unavailable").retryable());

    http.fail("the network connection was lost");
    let error = ready(cloud.get("as_1")).expect_err("no answer");
    assert!(error.is_transport() && error.retryable());

    http.answer(200, json!({ "not": "a session" }));
    assert!(!ready(cloud.get("as_1")).expect_err("unreadable").retryable());
}

#[test]
fn a_phone_never_asks_for_a_holders_route_or_a_made_up_path() {
    let http = Scripted::default();
    let cloud = HttpAutoCloud::new(&http);
    let fence = Fence::new(Holder::device("phone"), 1);
    let lease = LeaseRequest { holder: Holder::device("phone"), epoch: 1, needs_run: true, standby: None };
    let machine = MachineSetting { team: "team_1".into(), machine: "vm_1".into() };

    assert_eq!(ready(cloud.lease("as_1", &lease)).expect_err("refused").status(), Some(403));
    assert_eq!(ready(cloud.release("as_1", &fence)).expect_err("refused").status(), Some(403));
    assert_eq!(ready(cloud.inbox("as_1", 0)).expect_err("refused").status(), Some(403));
    assert_eq!(ready(cloud.snapshot("as_1")).expect_err("refused").status(), Some(403));
    assert_eq!(ready(cloud.set_machine(&machine)).expect_err("refused").status(), Some(403));
    assert_eq!(ready(cloud.assignments(0)).expect_err("refused").status(), Some(403));

    // An id that is not a chat's never becomes part of a path.
    let message = InboxPost { id: "m-1".into(), text: "go".into() };
    for id in ["", "../machine", "a/b", "a?b=c", "machine", "assignments", "a b"] {
        assert_eq!(ready(cloud.get(id)).expect_err("no such chat").status(), Some(404), "{id:?}");
        assert_eq!(
            ready(cloud.post_inbox(id, &message)).expect_err("no such chat").status(),
            Some(404),
            "{id:?}"
        );
    }
    assert!(http.asked().is_empty());

    // A chat id may hold a colon; it goes percent-encoded.
    http.answer(200, json!({ "session": session("a:b", "cloud", 0, 1) }));
    ready(cloud.get("a:b")).expect("the chat");
    assert_eq!(http.asked(), ["GET /v1/auto-sessions/a%3Ab"]);
}
