//! A person's digest over the hosted forum, through a fake transport that answers the feed the
//! way the hosted API does (`after`, `space`, an etag and `304`).

use acpmux_team_space::digest::{DigestOptions, Person};
use acpmux_team_space::hosted::HostedStore;
use acpmux_team_space::log::{CursorLog, JsonlLog, MemoryLog, RecordLog};
use acpmux_team_space::service::{ActError, Ask, DEFAULT_BUDGET, act, run};
use acpmux_team_space::{Action, TeamSpaceStore};
use cmux_forum_hosted::{
    Credential, ForumClient, Method, Request, Response, Transport, TransportError,
};
use serde_json::{Value, json};
use std::sync::{Arc, Mutex};

const SPACE: &str = "team";

#[derive(Clone, Default)]
struct Hosted {
    events: Arc<Mutex<Vec<Value>>>,
    duplicate_first: Arc<Mutex<bool>>,
    feed_requests: Arc<Mutex<Vec<Request>>>,
}

impl Hosted {
    fn add(&self, kind: &str, thread: u64, title: &str, comment: Option<&str>, actor: &str) {
        let mut events = self.events.lock().unwrap();
        let seq = events.len() as u64 + 1;
        events.push(json!({
            "seq": seq, "kind": kind, "at": "2026-11-23T08:00:00Z", "space": SPACE,
            "thread": thread, "title": title, "state": "open",
            "actor": {"kind": "agent", "id": actor},
            "comment": comment.map(|c| json!({"id": seq, "author": {"kind": "agent", "name": actor}, "excerpt": c, "cut": false, "length": c.len()})),
        }));
    }
}

fn query(req: &Request, name: &str) -> Option<String> {
    let q = req.path_and_query.split_once('?')?.1;
    q.split('&')
        .find_map(|p| p.split_once('=').filter(|(k, _)| *k == name).map(|(_, v)| v.to_owned()))
}

impl Transport for Hosted {
    async fn send(&self, req: Request) -> Result<Response, TransportError> {
        assert_eq!(req.method, Method::Get);
        assert!(req.path_and_query.starts_with("/v1/forum/feed"), "{}", req.path_and_query);
        self.feed_requests.lock().unwrap().push(req.clone());
        let after: u64 = query(&req, "after").unwrap().parse().unwrap();
        let all = self.events.lock().unwrap().clone();
        let head = all.len() as u64;
        let etag = format!("\"{head}\"");
        let sent = req.headers.iter().find(|(k, _)| k == "if-none-match").map(|(_, v)| v.clone());
        if sent.as_deref() == Some(etag.as_str()) {
            return Ok(Response { status: 304, headers: vec![], body: vec![] });
        }
        let mut events: Vec<Value> =
            all.into_iter().filter(|e| e["seq"].as_u64().unwrap() > after).collect();
        if *self.duplicate_first.lock().unwrap() && !events.is_empty() {
            events.insert(0, events[0].clone());
        }
        let body = json!({"events": events, "next": head, "head": head});
        Ok(Response {
            status: 200,
            headers: vec![("etag".into(), etag)],
            body: serde_json::to_vec(&body).unwrap(),
        })
    }
}

struct Rig {
    hosted: Hosted,
    rt: tokio::runtime::Runtime,
}

impl Rig {
    fn new() -> Self {
        Self {
            hosted: Hosted::default(),
            rt: tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap(),
        }
    }

    fn store(&self, log: Arc<dyn RecordLog>) -> HostedStore<Hosted> {
        let client = ForumClient::new(
            self.hosted.clone(),
            "team-a",
            Credential::Session { access_token: "t".into() },
        );
        HostedStore::new(Arc::new(client), self.rt.handle().clone(), log)
    }
}

fn leo() -> Person {
    Person { id: "leo".into(), handle: "leo".into(), agents: vec!["agent-7".into()], areas: vec![] }
}

fn read(
    store: &HostedStore<Hosted>,
    cursors: &dyn CursorLog,
    ack: bool,
    now: u64,
) -> acpmux_team_space::service::Run {
    let person = leo();
    run(
        store,
        cursors,
        &Ask {
            person: &person,
            space: SPACE,
            options: &DigestOptions::default(),
            budget: DEFAULT_BUDGET,
            ack,
            now,
            since: 0,
        },
    )
    .unwrap()
}

fn scripted(rig: &Rig) {
    rig.hosted.add("thread.created", 1, "Is the build red? @leo can you look", None, "agent-2");
    rig.hosted.add("thread.created", 2, "@bob should we ship Friday?", None, "agent-3");
    rig.hosted.add("comment.created", 3, "release notes", Some("drafted"), "agent-4");
}

#[test]
fn a_mention_is_raised_and_a_question_for_someone_else_is_summarized() {
    let rig = Rig::new();
    scripted(&rig);
    let log = Arc::new(MemoryLog::new());
    let store = rig.store(log.clone());
    let got = read(&store, &*log, false, 10);
    assert_eq!(got.digest.posts_seen, 3);
    let raised: Vec<_> = got.digest.needs_you.iter().map(|e| e.id.as_str()).collect();
    assert_eq!(raised, ["team/t1"]);
    assert!(got.digest.affects_you.is_empty());
    let rest: usize = got.digest.rest.iter().map(|g| g.posts).sum();
    assert_eq!(rest, 2, "{:?}", got.digest.rest);
    assert!(got.digest.item("team/t2").is_some_and(|e| e.reasons.is_empty()));
    assert_eq!((got.stats.raised, got.stats.summarized, got.stats.posts_seen), (1, 2, 3));
}

#[test]
fn the_cursor_moves_only_with_ack() {
    let rig = Rig::new();
    scripted(&rig);
    let log = Arc::new(MemoryLog::new());
    let store = rig.store(log.clone());
    let first = read(&store, &*log, false, 10);
    assert_eq!((first.acked, first.cursor), (false, 0));
    let again = read(&store, &*log, false, 11);
    assert_eq!(again.digest.posts_seen, 3, "an unacked digest is read again, in full");
    assert_eq!(again.stats.posts_seen, 3, "and its posts are counted once");
    let acked = read(&store, &*log, true, 12);
    assert_eq!((acked.acked, acked.cursor), (true, 3));
    let next = read(&store, &*log, false, 13);
    assert_eq!(next.digest.posts_seen, 0);
}

#[test]
fn an_unchanged_feed_is_an_empty_digest_not_an_error() {
    let rig = Rig::new();
    scripted(&rig);
    let log = Arc::new(MemoryLog::new());
    let store = rig.store(log.clone());
    read(&store, &*log, true, 10);
    read(&store, &*log, false, 11);
    let third = read(&store, &*log, false, 12);
    assert_eq!(third.digest.posts_seen, 0);
    assert!(third.digest.needs_you.is_empty());
    let sent = rig.hosted.feed_requests.lock().unwrap();
    let last = sent.last().unwrap();
    assert!(
        last.headers.iter().any(|(k, _)| k == "if-none-match"),
        "the last read was conditional"
    );
}

#[test]
fn a_304_for_an_unacked_read_repeats_the_same_digest() {
    let rig = Rig::new();
    scripted(&rig);
    let log = Arc::new(MemoryLog::new());
    let store = rig.store(log.clone());
    read(&store, &*log, false, 10);
    let second = read(&store, &*log, false, 11);
    assert_eq!(second.digest.posts_seen, 3);
    assert!(
        rig.hosted
            .feed_requests
            .lock()
            .unwrap()
            .last()
            .unwrap()
            .headers
            .iter()
            .any(|(k, _)| k == "if-none-match")
    );
}

#[test]
fn a_seq_delivered_twice_is_counted_once() {
    let rig = Rig::new();
    scripted(&rig);
    *rig.hosted.duplicate_first.lock().unwrap() = true;
    let log = Arc::new(MemoryLog::new());
    let store = rig.store(log.clone());
    let got = read(&store, &*log, false, 10);
    assert_eq!(got.digest.posts_seen, 3);
    assert_eq!(got.stats.posts_seen, 3);
}

#[test]
fn actions_and_the_cursor_survive_a_restart() {
    let rig = Rig::new();
    scripted(&rig);
    let dir =
        std::env::temp_dir().join(format!("team-feed-hosted-{}-{}", std::process::id(), line!()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("digest.jsonl");
    {
        let log = Arc::new(JsonlLog::open(&path).unwrap());
        let store = rig.store(log.clone());
        let got = read(&store, &*log, true, 10);
        assert_eq!(got.cursor, 3);
        act(&store, "leo", SPACE, "team/t1", Action::Opened, 20).unwrap();
        act(&store, "leo", SPACE, "team/t1", Action::Answered, 21).unwrap();
        act(&store, "leo", SPACE, "team/t2", Action::Dismissed, 22).unwrap();
        assert_eq!(
            act(&store, "leo", SPACE, "team/t99", Action::Opened, 23),
            Err(ActError::UnknownItem("team/t99".into()))
        );
    }
    // A torn last write loses only itself.
    use std::io::Write;
    std::fs::OpenOptions::new()
        .append(true)
        .open(&path)
        .unwrap()
        .write_all(b"{\"type\":\"rec")
        .unwrap();
    let log = Arc::new(JsonlLog::open(&path).unwrap());
    let store = rig.store(log.clone());
    assert_eq!(log.cursor("leo", SPACE), 3);
    let now = read(&store, &*log, false, 30);
    assert_eq!(now.digest.posts_seen, 0);
    let (s, since) = (now.stats, 0);
    assert_eq!((s.opened, s.answered, s.dismissed), (1, 1, 1));
    assert_eq!((s.posts_seen, s.raised, s.summarized), (3, 1, 2));
    assert_eq!(acpmux_team_space::record::stats(&store, "leo", since).unwrap().answered, 1);
    assert_eq!(acpmux_team_space::record::stats(&store, "leo", 22).unwrap().answered, 0);
    assert_eq!(store.records("leo", 22).unwrap().len(), 1);
    std::fs::remove_file(&path).unwrap();
    std::fs::remove_dir(&dir).unwrap();
}
