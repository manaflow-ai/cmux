//! A sign-in that waits on the person is an open Feed request (the Feed's
//! pinned Needs you, which Home and the iPhone read), and it closes when the
//! Chief tells the subagent it is signed in or the subagent is cancelled.

mod common;

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use common::*;
use optchat_chief::needs_you_feed::{self, FeedPort};
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::{AuthEscalation, ControlCall, Orchestrator};
use serde_json::Value;

#[derive(Default)]
struct Recorded {
    posts: Vec<(Value, String)>,
    cancels: Vec<(String, String)>,
}

#[derive(Default)]
struct RecordingFeed(Mutex<Recorded>);

impl FeedPort for RecordingFeed {
    fn request(&self, post: &Value, key: &str) -> Result<String, String> {
        let mut r = self.0.lock().unwrap();
        r.posts.push((post.clone(), key.to_owned()));
        Ok(format!("fi_{:020}", r.posts.len()))
    }

    fn cancel(&self, item: &str, reason: &str) -> Result<(), String> {
        self.0
            .lock()
            .unwrap()
            .cancels
            .push((item.to_owned(), reason.to_owned()));
        Ok(())
    }
}

impl RecordingFeed {
    fn wait(&self, what: &str, done: impl Fn(&Recorded) -> bool) {
        let deadline = Instant::now() + Duration::from_secs(10);
        while !done(&self.0.lock().unwrap()) {
            assert!(Instant::now() < deadline, "the Feed never got {what}");
            std::thread::sleep(Duration::from_millis(5));
        }
    }
}

fn spawner(h: &Harness) -> Arc<Spawner> {
    Arc::new(Spawner::new(
        h.chat.clone(),
        h.agents.clone(),
        SubagentSettings {
            harness: "claude".into(),
            policy: "approve-all".into(),
            model: None,
            effort: None,
            preset: Some("optchat-sub-h0me".into()),
            cwd: h.dir.path().join("subagent"),
            prefix: "optchat-sub-h0me".into(),
            parent: optchat_chief::brain::PARENT.into(),
            claude_md: None,
        },
        h.tx.clone(),
        Arc::new(|_: &str| {}),
    ))
}

fn run<T: Send + 'static>(h: &mut Harness, f: impl FnOnce() -> T + Send + 'static) -> T {
    let worker = std::thread::spawn(f);
    while !worker.is_finished() {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(10)) {
            h.brain.step(input);
        }
    }
    worker.join().unwrap()
}

fn npm(kind: &str) -> AuthEscalation {
    AuthEscalation {
        site: "npmjs.com".into(),
        url: "https://www.npmjs.com/login?next=/settings".into(),
        reason: "add the cmux-tui nightly trusted publisher".into(),
        kind: kind.into(),
    }
}

/// A brain with a spawned `a1` whose sign-ins post to `feed`.
fn with_a1(feed: &Arc<RecordingFeed>) -> (Harness, Arc<Spawner>) {
    let mut h = Harness::new(default_script());
    h.brain.set_feed(Some(feed.clone() as Arc<dyn FeedPort>));
    h.connect();
    let sp = spawner(&h);
    let a = sp.clone();
    run(&mut h, move || {
        a.spawn(vec!["publish the nightly".into()], None)
    })
    .unwrap();
    (h, sp)
}

#[test]
fn an_escalated_sign_in_is_an_open_needs_you_request_in_the_feed() {
    let feed = Arc::new(RecordingFeed::default());
    let (mut h, sp) = with_a1(&feed);
    let b = sp.clone();
    run(&mut h, move || b.escalate_auth("a1", &npm("2fa"))).unwrap();

    feed.wait("the sign-in request", |r| !r.posts.is_empty());
    let (post, key) = feed.0.lock().unwrap().posts[0].clone();
    assert_eq!(post["dedupe_key"], "chief-auth:h0me:a1:npmjs.com");
    // One idempotency key per escalation: a later one is not a replay of a closed item.
    assert!(key.starts_with("chief-auth:h0me:a1:npmjs.com:"), "{key}");
    assert_eq!(post["type"], "request");
    assert_eq!(post["kind"], "sign-in");
    assert_eq!(post["title"], "Sign in to npmjs.com");
    assert_eq!(post["prompt"]["origin"], "https://www.npmjs.com");
    assert_eq!(
        post["prompt"]["url"],
        "https://www.npmjs.com/login?next=/settings"
    );
    assert_eq!(
        post["prompt"]["reason"],
        "add the cmux-tui nightly trusted publisher"
    );
    assert!(
        post["prompt"]["browser_tab"]
            .as_str()
            .is_some_and(|t| !t.is_empty())
    );
    assert!(post["expires_in_ms"].as_u64().is_some());
    assert_eq!(
        h.brain.open_sign_ins(),
        vec!["chief-auth:h0me:a1:npmjs.com".to_owned()]
    );
}

#[test]
fn a_passkey_escalation_posts_a_passkey_request() {
    let post = needs_you_feed::post("h0me", "a2", &npm("passkey"), Some("sess-1"));
    assert_eq!(post["kind"], "passkey");
    assert_eq!(post["prompt"]["ceremony"], "get");
    assert_eq!(post["prompt"]["rp_id"], "npmjs.com");
    assert_eq!(post["context"]["acp_session"], "sess-1");
    assert_eq!(post["dedupe_key"], "chief-auth:h0me:a2:npmjs.com");
}

#[test]
fn telling_the_subagent_it_is_signed_in_closes_the_request() {
    let feed = Arc::new(RecordingFeed::default());
    let (mut h, sp) = with_a1(&feed);
    let b = sp.clone();
    run(&mut h, move || b.escalate_auth("a1", &npm("passkey"))).unwrap();
    feed.wait("the passkey request", |r| !r.posts.is_empty());

    // An unrelated message leaves it open.
    let c = sp.clone();
    run(&mut h, move || c.tell("a1", "also bump the changelog")).unwrap();
    assert_eq!(h.brain.open_sign_ins().len(), 1);

    let d = sp.clone();
    run(&mut h, move || {
        d.tell("a1", "Signed in to npmjs.com in tab tab_3; go on.")
    })
    .unwrap();
    feed.wait("the cancel", |r| !r.cancels.is_empty());
    let r = feed.0.lock().unwrap();
    assert_eq!(
        r.cancels,
        vec![(format!("fi_{:020}", 1), "answered_elsewhere".to_owned())]
    );
    drop(r);
    assert!(h.brain.open_sign_ins().is_empty());
}

#[test]
fn cancelling_the_subagent_withdraws_its_sign_in() {
    let feed = Arc::new(RecordingFeed::default());
    let (mut h, sp) = with_a1(&feed);
    let b = sp.clone();
    run(&mut h, move || b.escalate_auth("a1", &npm("password"))).unwrap();
    feed.wait("the sign-in request", |r| !r.posts.is_empty());

    let c = sp.clone();
    run(&mut h, move || {
        c.control(ControlCall {
            action: "cancel".into(),
            id: Some("a1".into()),
            ..Default::default()
        })
    })
    .unwrap();
    feed.wait("the cancel", |r| !r.cancels.is_empty());
    assert_eq!(feed.0.lock().unwrap().cancels[0].1, "poster_gone");
    assert!(h.brain.open_sign_ins().is_empty());
}

#[test]
fn a_signed_in_message_names_its_site_unless_it_is_the_only_one() {
    use needs_you_feed::says_signed_in;
    assert!(says_signed_in(
        "Signed in to npmjs.com in tab t; go on.",
        "npmjs.com",
        false
    ));
    assert!(says_signed_in(
        "Signed in to npmjs.com",
        "www.npmjs.com",
        false
    ));
    assert!(!says_signed_in(
        "Signed in to github.com",
        "npmjs.com",
        false
    ));
    assert!(says_signed_in(
        "You're signed in now; go on.",
        "npmjs.com",
        true
    ));
    assert!(!says_signed_in(
        "The user did not touch the sensor in 10 minutes.",
        "npmjs.com",
        true
    ));
    assert!(!says_signed_in(
        "You're not signed in yet; wait.",
        "npmjs.com",
        true
    ));
    assert!(!says_signed_in(
        "npmjs.com isn't logged in yet",
        "npmjs.com",
        false
    ));
}
