//! A work thread posts to a team space and a teammate's agent reads it, against the fake store.

use acpmux_team_space::delivery::{DIGEST_TEXT_CHARS, classify};
use acpmux_team_space::fake::{FakeClient, FakeStore};
use acpmux_team_space::thread::{MAX_PAGES_PER_PULL, PAGE_LIMIT};
use acpmux_team_space::{
    AgentIdentity, Delivery, Event, PostKind, StoreError, TeamSpaceReader, TeamSpaceStore,
    WakePolicy, WorkThread,
};

const SPACE: &str = "team/eng";

fn identity(id: &str, address: &str, person: &str) -> AgentIdentity {
    AgentIdentity {
        id: id.to_owned(),
        team_address: address.to_owned(),
        on_behalf_of: person.to_owned(),
        session: Some(format!("{id}-session")),
        host: Some(format!("{id}-host")),
    }
}

fn client(store: &FakeStore, me: &AgentIdentity) -> FakeClient {
    store.client(FakeClient::agent_author(
        &me.id,
        &me.team_address,
        &me.on_behalf_of,
        me.session.as_deref(),
        me.host.as_deref(),
    ))
}

struct Team {
    store: FakeStore,
    asker: AgentIdentity,
    answerer: AgentIdentity,
}

fn team() -> Team {
    let store = FakeStore::new();
    let asker = identity("agent-a", "@team/builder", "person-a");
    let answerer = identity("agent-b", "@team/reviewer", "person-b");
    store.admit(SPACE, &asker.id);
    store.admit(SPACE, &answerer.id);
    Team { store, asker, answerer }
}

#[test]
fn default_policy_is_ask_first() {
    assert_eq!(WakePolicy::default(), WakePolicy::AskFirst);
    assert_eq!(WakePolicy::from_setting(None), WakePolicy::AskFirst);
    for value in ["", "wake", "WakeFromTeam", "true", "on", "wakeFromTeamX"] {
        assert_eq!(WakePolicy::from_setting(Some(value)), WakePolicy::AskFirst, "{value:?}");
    }
    assert_eq!(WakePolicy::from_setting(Some("wakeFromTeam")), WakePolicy::WakeFromTeam);
}

#[test]
fn addressed_question_waits_in_the_teammates_digest_and_wakes_nobody() {
    let t = team();
    let thread = WorkThread::new(SPACE, "pr:48220");
    thread
        .ask(&client(&t.store, &t.asker), &t.asker, "@team/reviewer", "is the seam ok?", "prompt-1")
        .expect("post");

    let mut reader = TeamSpaceReader::new(t.answerer.clone(), WakePolicy::default(), &[(SPACE, 0)]);
    let pull = reader.pull(&client(&t.store, &t.answerer));
    assert!(pull.failed.is_empty(), "{:?}", pull.failed);
    assert_eq!(pull.deliveries.len(), 1);
    let Delivery::Digest(item) = &pull.deliveries[0] else {
        panic!("ask-first must digest, got {:?}", pull.deliveries[0]);
    };
    assert!(item.addressed);
    assert_eq!(item.thread, "pr:48220");
    assert_eq!(item.kind, PostKind::Question);
    assert_eq!(item.author.id, "agent-a");
    assert_eq!(item.author.on_behalf_of.as_deref(), Some("person-a"));
    assert_eq!(item.author.session.as_deref(), Some("agent-a-session"));
    assert!(pull.deliveries.iter().all(|d| !matches!(d, Delivery::Wake(_))));
}

#[test]
fn only_the_owners_opt_in_wakes_and_only_for_a_question() {
    let t = team();
    let thread = WorkThread::new(SPACE, "topic:forum");
    let asker = client(&t.store, &t.asker);
    thread.ask(&asker, &t.asker, "@team/reviewer", "q", "p1").unwrap();
    thread.post(&asker, &t.asker, PostKind::Finding, "f", &["@team/reviewer"], "p2").unwrap();

    let mut reader =
        TeamSpaceReader::new(t.answerer.clone(), WakePolicy::WakeFromTeam, &[(SPACE, 0)]);
    let pull = reader.pull(&client(&t.store, &t.answerer));
    assert!(matches!(pull.deliveries[0], Delivery::Wake(_)));
    assert!(matches!(pull.deliveries[1], Delivery::Digest(_)));
}

#[test]
fn own_and_unaddressed_posts_are_not_delivered_but_stay_readable() {
    let t = team();
    let thread = WorkThread::new(SPACE, "topic:forum");
    let asker = client(&t.store, &t.asker);
    thread.post(&asker, &t.asker, PostKind::Status, "working on it", &[], "p1").unwrap();
    thread.ask(&asker, &t.asker, "@team/someone-else", "q", "p2").unwrap();

    let mut own = TeamSpaceReader::new(t.asker.clone(), WakePolicy::default(), &[(SPACE, 0)]);
    assert!(own.pull(&asker).deliveries.is_empty());
    let mut other = TeamSpaceReader::new(t.answerer.clone(), WakePolicy::default(), &[(SPACE, 0)]);
    let answerer = client(&t.store, &t.answerer);
    assert!(other.pull(&answerer).deliveries.is_empty());
    assert_eq!(other.cursor(SPACE), Some(2), "the cursor still moves past what it skipped");
    // The teammate's chat sees the thread.
    let page = answerer.feed(SPACE, 0, 10).unwrap();
    assert_eq!(page.events.len(), 2);
    assert!(page.events.iter().all(|e| e.thread == "topic:forum"));
}

#[test]
fn a_resent_prompt_is_one_post() {
    let t = team();
    let thread = WorkThread::new(SPACE, "pr:1");
    let asker = client(&t.store, &t.asker);
    let first = thread.ask(&asker, &t.asker, "@team/reviewer", "q", "same").unwrap();
    let again = thread.ask(&asker, &t.asker, "@team/reviewer", "q", "same").unwrap();
    assert_eq!(first, again);
    let mut reader = TeamSpaceReader::new(t.answerer.clone(), WakePolicy::default(), &[(SPACE, 0)]);
    assert_eq!(reader.pull(&client(&t.store, &t.answerer)).deliveries.len(), 1);
}

#[test]
fn a_space_the_agent_was_not_admitted_to_is_refused() {
    let t = team();
    let outsider = identity("agent-c", "@team/outsider", "person-c");
    let thread = WorkThread::new(SPACE, "pr:1");
    let refused = thread.ask(&client(&t.store, &outsider), &outsider, "@team/reviewer", "q", "p");
    assert_eq!(refused, Err(StoreError::Forbidden { space: SPACE.to_owned() }));

    let mut reader = TeamSpaceReader::new(outsider.clone(), WakePolicy::default(), &[(SPACE, 0)]);
    let pull = reader.pull(&client(&t.store, &outsider));
    assert_eq!(
        pull.failed,
        vec![(SPACE.to_owned(), StoreError::Forbidden { space: SPACE.to_owned() })]
    );
    assert_eq!(reader.cursor(SPACE), Some(0));
}

#[test]
fn an_unavailable_store_keeps_the_cursor_and_the_next_pull_resumes() {
    let t = team();
    let thread = WorkThread::new(SPACE, "pr:1");
    thread.ask(&client(&t.store, &t.asker), &t.asker, "@team/reviewer", "q1", "p1").unwrap();
    let answerer = client(&t.store, &t.answerer);
    let mut reader = TeamSpaceReader::new(t.answerer.clone(), WakePolicy::default(), &[(SPACE, 0)]);

    t.store.set_unavailable(true);
    let down = reader.pull(&answerer);
    assert!(down.deliveries.is_empty());
    assert!(matches!(down.failed[0].1, StoreError::Unavailable(_)));
    assert_eq!(reader.cursor(SPACE), Some(0));

    t.store.set_unavailable(false);
    let up = reader.pull(&answerer);
    assert_eq!(up.deliveries.len(), 1);
    assert_eq!(reader.cursor(SPACE), Some(1));
    assert!(
        reader.pull(&answerer).deliveries.is_empty(),
        "a caught-up pull delivers nothing again"
    );
}

#[test]
fn a_busy_space_is_read_in_bounded_pages() {
    let t = team();
    let thread = WorkThread::new(SPACE, "pr:1");
    let asker = client(&t.store, &t.asker);
    let total = PAGE_LIMIT * MAX_PAGES_PER_PULL + 5;
    for i in 0..total {
        thread.ask(&asker, &t.asker, "@team/reviewer", "q", &format!("p{i}")).unwrap();
    }
    let answerer = client(&t.store, &t.answerer);
    let mut reader = TeamSpaceReader::new(t.answerer.clone(), WakePolicy::default(), &[(SPACE, 0)]);
    let calls = t.store.feed_calls();
    let first = reader.pull(&answerer);
    assert_eq!(t.store.feed_calls() - calls, MAX_PAGES_PER_PULL);
    assert_eq!(first.deliveries.len(), PAGE_LIMIT * MAX_PAGES_PER_PULL);
    assert_eq!(first.behind, vec![SPACE.to_owned()]);
    let rest = reader.pull(&answerer);
    assert_eq!(rest.deliveries.len(), 5);
    assert!(rest.behind.is_empty());
    assert_eq!(reader.cursor(SPACE), Some(total as u64));
}

#[test]
fn digest_text_is_cut_with_a_marker() {
    let me = identity("agent-b", "@team/reviewer", "person-b");
    let long = "x".repeat(DIGEST_TEXT_CHARS + 20);
    let event = Event {
        seq: 1,
        space: SPACE.to_owned(),
        thread: "pr:1".to_owned(),
        post_id: "p1".to_owned(),
        kind: PostKind::Question,
        author: FakeClient::agent_author("agent-a", "@team/builder", "person-a", None, None),
        text: long,
        to: vec!["@team/reviewer".to_owned()],
        dedupe: None,
        areas: Vec::new(),
    };
    let item = classify(&event, &me, WakePolicy::AskFirst).item().cloned().unwrap();
    assert!(item.text.ends_with(" [cut 20]"), "{}", item.text);
}

#[test]
fn an_unknown_post_kind_from_a_newer_store_is_never_a_question() {
    let raw = r#"{"seq":1,"space":"s","thread":"t","postId":"p","kind":"poll",
        "author":{"kind":"agent","id":"a"},"text":"x","to":["@team/reviewer"]}"#;
    let event: Event = serde_json::from_str(raw).unwrap();
    assert_eq!(event.kind, PostKind::Other);
    let me = identity("agent-b", "@team/reviewer", "person-b");
    assert!(matches!(classify(&event, &me, WakePolicy::WakeFromTeam), Delivery::Digest(_)));
}
