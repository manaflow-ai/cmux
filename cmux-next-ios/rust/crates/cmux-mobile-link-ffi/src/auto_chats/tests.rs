//! The Auto chats surface as the app calls it: over an HTTP path the test answers.

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use tokio::sync::watch;

use super::{AutoChatError, AutoChats, AutoHttp, AutoHttpError, AutoHttpReply, AutoHttpRequest};

/// The app's side: it answers what it was told to, in order, and holds a request it has no
/// answer for.
struct Scripted {
    asked: Mutex<Vec<AutoHttpRequest>>,
    answers: Mutex<VecDeque<Result<AutoHttpReply, AutoHttpError>>>,
    /// How many requests arrived.
    arrived: watch::Sender<usize>,
}

impl Scripted {
    fn new() -> Arc<Scripted> {
        let (arrived, _) = watch::channel(0);
        Arc::new(Scripted { asked: Mutex::default(), answers: Mutex::default(), arrived })
    }

    fn answer(&self, status: u16, body: Value) {
        let reply = AutoHttpReply { status, body: body.to_string() };
        self.answers.lock().expect("answers").push_back(Ok(reply));
    }

    fn fail(&self, why: &str) {
        let error = AutoHttpError::Failed { message: why.to_owned() };
        self.answers.lock().expect("answers").push_back(Err(error));
    }

    /// Every request so far, as `METHOD path`.
    fn asked(&self) -> Vec<String> {
        let asked = self.asked.lock().expect("asked");
        asked.iter().map(|request| format!("{} {}", request.method, request.path)).collect()
    }

    /// Returns once `count` requests arrived.
    async fn arrived(&self, count: usize) {
        let mut arrived = self.arrived.subscribe();
        arrived.wait_for(|seen| *seen >= count).await.expect("the transport");
    }
}

#[async_trait::async_trait]
impl AutoHttp for Scripted {
    async fn send(&self, request: AutoHttpRequest) -> Result<AutoHttpReply, AutoHttpError> {
        self.asked.lock().expect("asked").push(request);
        self.arrived.send_modify(|seen| *seen += 1);
        let answer = self.answers.lock().expect("answers").pop_front();
        match answer {
            Some(answer) => answer,
            None => std::future::pending().await,
        }
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
    })
}

fn read(text: Result<String, AutoChatError>) -> Value {
    serde_json::from_str(&text.expect("an answer")).expect("JSON")
}

/// An open chat with one record, and the app's side it reads through.
async fn open_chat() -> (Arc<Scripted>, Arc<super::AutoChat>) {
    let http = Scripted::new();
    let chat = AutoChats::new(http.clone()).chat("as_1".to_owned());
    let record = json!({ "sessionId": "x", "seq": 1, "at": 5, "dir": "mux", "kind": "turn_started",
                         "msg": { "turnId": "t1" } });
    http.answer(200, json!({ "session": session("as_1", "cloud", 1, 7) }));
    http.answer(200, json!({ "events": [{ "seq": 1, "record": record }], "lastSeq": 1 }));
    let opened = read(chat.open().await);
    assert_eq!(opened["records"][0]["kind"], "turn_started");
    assert_eq!(opened["records"][0]["sessionId"], "as_1");
    assert_eq!(opened["chat"]["place"], "cloud");
    (http, chat)
}

#[tokio::test]
async fn the_list_and_a_new_chat_cross_as_json() {
    let http = Scripted::new();
    let chats = AutoChats::new(http.clone());

    http.answer(200, json!({ "sessions": [session("as_1", "cloud", 3, 7)], "nextCursor": null }));
    let list = read(chats.list().await);
    assert_eq!(list["chats"][0]["id"], "as_1");
    assert_eq!(list["chats"][0]["place"], "cloud");
    assert_eq!(list["chats"][0]["keepInCloud"], false);
    assert_eq!(list["repos"], json!([{ "remote": "https://example.com/app.git", "branch": "main" }]));
    let asked = http.asked.lock().expect("asked").last().cloned().expect("a request");
    assert_eq!((asked.method.as_str(), asked.path.as_str()), ("GET", "/v1/auto-sessions?limit=100"));
    assert_eq!((asked.body, asked.timeout_ms), (None, 20_000));

    http.answer(201, json!({ "session": session("as_9", "resuming", 0, 1) }));
    let remote = "https://example.com/app.git".to_owned();
    let started = chats.start(remote.clone(), "main".to_owned(), "m-1".to_owned(), "go".to_owned()).await;
    let started = read(started);
    assert_eq!((&started["outcome"], &started["chat"]["id"]), (&json!("chat"), &json!("as_9")));
    assert_eq!(started["chat"]["place"], "resuming");

    http.answer(200, json!({ "team": "team_1", "machine": "vm_1" }));
    assert_eq!(chats.has_machine().await, Ok(true));
}

#[tokio::test]
async fn no_machine_is_an_outcome_and_a_refusal_keeps_its_code() {
    let http = Scripted::new();
    let chats = AutoChats::new(http.clone());
    let no_machine = json!({ "error": { "code": "auto.no_machine", "message": "no Auto machine is set" } });

    http.answer(404, no_machine.clone());
    assert_eq!(chats.has_machine().await, Ok(false));
    http.answer(404, no_machine);
    let started = chats.start("r".to_owned(), "main".to_owned(), "m-1".to_owned(), "go".to_owned()).await;
    assert_eq!(read(started), json!({ "outcome": "no_machine" }));

    http.answer(403, json!({ "error": { "code": "auth.forbidden", "message": "not yours" } }));
    assert_eq!(
        chats.list().await,
        Err(AutoChatError::Refused {
            status: 403,
            code: "auth.forbidden".to_owned(),
            message: "not yours".to_owned()
        })
    );

    http.fail("the network connection was lost");
    let error = chats.list().await.expect_err("no answer");
    assert!(matches!(error, AutoChatError::Unreachable { .. }), "{error:?}");
}

#[tokio::test]
async fn leaving_a_chat_ends_a_held_read() {
    let (http, chat) = open_chat().await;

    // The read is held: the app's side has no answer for it.
    let held = tokio::spawn({
        let chat = chat.clone();
        async move { chat.next().await }
    });
    http.arrived(3).await;
    assert_eq!(http.asked()[2], "GET /v1/auto-sessions/as_1/wait?after=7&timeoutMs=25000");

    chat.close();
    let last = read(held.await.expect("the read"));
    assert_eq!((&last["ended"], &last["records"]), (&json!(true), &json!([])));

    // A chat the app left is not read again.
    assert_eq!(read(chat.next().await)["ended"], true);
    assert_eq!(http.asked().len(), 3);
}

#[tokio::test]
async fn a_read_with_no_answer_waits_before_the_next_one() {
    let (http, chat) = open_chat().await;

    http.fail("the network connection was lost");
    let lost = read(chat.next().await);
    assert_eq!((&lost["ended"], &lost["records"]), (&json!(false), &json!([])));
    let wait = lost["retryAfterMs"].as_u64().expect("a wait");
    assert!(wait > 0);

    // The next read starts only after the wait, with nothing asked of the app.
    http.answer(200, json!({ "session": session("as_1", "cloud", 1, 7) }));
    let before = Instant::now();
    let next = read(chat.next().await);
    assert!(before.elapsed() >= Duration::from_millis(wait));
    assert_eq!(next["retryAfterMs"], Value::Null);
    assert_eq!(http.asked().len(), 4);
}

#[tokio::test]
async fn a_message_is_sent_under_its_id_and_a_chat_is_kept() {
    let (http, chat) = open_chat().await;

    http.answer(200, json!({ "state": "delivered", "session": session("as_1", "cloud", 1, 8) }));
    let sent = read(chat.send("m-1".to_owned(), "hello".to_owned()).await);
    assert_eq!(sent["records"][0]["kind"], "queued");
    assert_eq!(sent["records"][0]["msg"]["promptId"], "m-1");
    let asked = http.asked.lock().expect("asked").last().cloned().expect("a request");
    assert_eq!((asked.method.as_str(), asked.path.as_str()), ("POST", "/v1/auto-sessions/as_1/inbox"));
    let body: Value = serde_json::from_str(&asked.body.expect("a body")).expect("JSON");
    assert_eq!(body, json!({ "id": "m-1", "text": "hello" }));

    let mut kept = session("as_1", "cloud", 1, 9);
    kept["keepInCloud"] = json!(true);
    http.answer(200, json!({ "session": kept }));
    assert_eq!(read(chat.keep(true).await)["chat"]["keepInCloud"], true);
}
