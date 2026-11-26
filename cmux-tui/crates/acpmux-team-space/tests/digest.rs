//! A person's digest of the team feed, against the fake store: each rule, the action log and its
//! read-back numbers, and degenerate feeds.

use acpmux_team_space::digest::{self, Reason, SeqGap};
use acpmux_team_space::fake::{FakeClient, FakeStore};
use acpmux_team_space::{
    Action, ActionRecord, Digest, DigestOptions, NewPost, Person, PersonRecord, PostKind,
    StoreError, TeamSpaceStore, stats,
};

const SPACE: &str = "team/eng";

fn leo() -> Person {
    Person {
        id: "leo".to_owned(),
        handle: "@leo".to_owned(),
        agents: vec!["agent-leo".to_owned(), "@team/leo-builder".to_owned()],
        areas: vec!["cmux-tui/crates/acpmux/**".to_owned(), "label:forum".to_owned()],
    }
}

fn austin() -> Person {
    Person {
        id: "austin".to_owned(),
        handle: "@austin".to_owned(),
        agents: vec!["agent-austin".to_owned()],
        areas: vec!["webviews/**".to_owned()],
    }
}

struct Feed {
    store: FakeStore,
}

impl Feed {
    fn new() -> Self {
        let store = FakeStore::new();
        for member in ["agent-a", "agent-b", "agent-leo", "agent-austin", "leo", "austin"] {
            store.admit(SPACE, member);
        }
        Self { store }
    }

    fn agent(&self, id: &str, person: &str) -> FakeClient {
        self.store.client(FakeClient::agent_author(id, &format!("@team/{id}"), person, None, None))
    }

    fn post(&self, by: &str, kind: PostKind, text: &str, to: &[&str]) -> u64 {
        self.post_with(by, kind, text, to, None, &[])
    }

    fn post_with(
        &self,
        by: &str,
        kind: PostKind,
        text: &str,
        to: &[&str],
        dedupe: Option<&str>,
        areas: &[&str],
    ) -> u64 {
        let owner = match by {
            "agent-leo" => "leo",
            "agent-austin" => "austin",
            _ => "someone",
        };
        let client = self.agent(by, owner);
        client
            .post(&NewPost {
                space: SPACE.to_owned(),
                thread: "topic:ci".to_owned(),
                kind,
                text: text.to_owned(),
                to: to.iter().map(|s| (*s).to_owned()).collect(),
                idempotency_key: format!("{by}:{}", next_id()),
                dedupe: dedupe.map(str::to_owned),
                areas: areas.iter().map(|s| (*s).to_owned()).collect(),
                reported_session: None,
                reported_host: None,
            })
            .unwrap()
            .seq
    }

    fn digest(&self, person: &Person, after: u64, prior: &[ActionRecord]) -> Digest {
        let reader = self.agent(&person.agents[0], &person.id);
        digest::read(&reader, person, SPACE, after, prior, &DigestOptions::default()).unwrap()
    }
}

fn next_id() -> u64 {
    use std::sync::atomic::{AtomicU64, Ordering};
    static N: AtomicU64 = AtomicU64::new(0);
    N.fetch_add(1, Ordering::Relaxed)
}

fn ids(entries: &[acpmux_team_space::DigestEntry]) -> Vec<u64> {
    entries.iter().map(|e| e.seq).collect()
}

#[test]
fn an_empty_feed_is_an_empty_digest() {
    let feed = Feed::new();
    let d = feed.digest(&leo(), 0, &[]);
    assert_eq!((d.posts_seen, d.duplicates_folded, d.to_seq, d.head), (0, 0, 0, 0));
    assert!(d.needs_you.is_empty() && d.affects_you.is_empty() && d.rest.is_empty());
    assert!(d.gaps.is_empty() && !d.behind);
    let r = d.render(500);
    assert_eq!(r.text, "Team feed team/eng for @leo: no new posts after #0.\n");
    assert_eq!(r.cut, 0);
}

#[test]
fn addressed_questions_and_blockers_and_mentions_need_you() {
    let feed = Feed::new();
    let q = feed.post("agent-a", PostKind::Question, "Can I land #49357?", &["@leo"]);
    let b = feed.post("agent-a", PostKind::Blocker, "CI runner gone", &["@team/leo-builder"]);
    let m = feed.post("agent-b", PostKind::Win, "Shipped it, thanks @agent-leo.", &[]);
    let d = feed.digest(&leo(), 0, &[]);
    assert_eq!(ids(&d.needs_you), vec![q, b, m]);
    assert_eq!(d.needs_you[0].reasons, vec![Reason::Addressed { to: "@leo".to_owned() }]);
    assert_eq!(d.needs_you[2].reasons, vec![Reason::Mentioned { name: "@agent-leo".to_owned() }]);
    assert!(d.affects_you.is_empty() && d.rest.is_empty());
}

#[test]
fn other_addressed_posts_and_area_posts_affect_you() {
    let feed = Feed::new();
    let fyi = feed.post("agent-a", PostKind::Fyi, "Rotated the key", &["leo"]);
    let path = feed.post(
        "agent-a",
        PostKind::Change,
        "Renamed cmux-tui/crates/acpmux/src/hub/inbox.rs.",
        &[],
    );
    let label =
        feed.post_with("agent-b", PostKind::Breakage, "Forum 500s", &[], None, &["label:Forum"]);
    let other = feed.post("agent-b", PostKind::Change, "Moved webviews/src/app.tsx", &[]);
    let d = feed.digest(&leo(), 0, &[]);
    assert!(d.needs_you.is_empty());
    assert_eq!(ids(&d.affects_you), vec![fyi, path, label]);
    assert_eq!(
        d.affects_you[1].reasons,
        vec![Reason::Area {
            area: "cmux-tui/crates/acpmux/**".to_owned(),
            matched: "cmux-tui/crates/acpmux/src/hub/inbox.rs".to_owned(),
        }]
    );
    assert_eq!(d.rest.len(), 1);
    assert_eq!(ids(&d.rest[0].items), vec![other]);
    // The same post touches Austin's area instead.
    let a = feed.digest(&austin(), 0, &[]);
    assert_eq!(ids(&a.affects_you), vec![other]);
}

#[test]
fn rest_is_grouped_by_kind_with_counts_and_own_posts_are_rest() {
    let feed = Feed::new();
    feed.post("agent-a", PostKind::Win, "win one", &[]);
    feed.post("agent-b", PostKind::Win, "win two", &[]);
    feed.post("agent-b", PostKind::Win, "win two!", &[]);
    feed.post("agent-a", PostKind::Status, "status", &[]);
    let own = feed.post("agent-leo", PostKind::Question, "asking myself @leo", &["@leo"]);
    let d = feed.digest(&leo(), 0, &[]);
    assert!(d.needs_you.is_empty(), "own posts never need you");
    let kinds: Vec<_> = d.rest.iter().map(|g| (g.kind, g.posts, g.items.len())).collect();
    assert_eq!(
        kinds,
        vec![(PostKind::Win, 3, 2), (PostKind::Question, 1, 1), (PostKind::Status, 1, 1)]
    );
    assert_eq!(d.rest[1].items[0].seq, own);
    assert_eq!(d.duplicates_folded, 1);
}

#[test]
fn duplicates_fold_by_dedupe_key_or_normalized_text_with_every_attribution() {
    let feed = Feed::new();
    let first =
        feed.post_with("agent-a", PostKind::Breakage, "main is red", &[], Some("ci:main"), &[]);
    feed.post_with("agent-b", PostKind::Breakage, "Main: build broken", &[], Some("ci:main"), &[]);
    feed.post("agent-austin", PostKind::Breakage, "MAIN is red!!", &[]);
    // Same text later addressed to Leo: the folded item moves up to needs-you.
    feed.post("agent-b", PostKind::Question, "main   is red?", &["@leo"]);
    let d = feed.digest(&leo(), 0, &[]);
    assert_eq!(d.posts_seen, 4);
    assert_eq!(d.duplicates_folded, 3);
    assert_eq!(d.needs_you.len(), 1);
    let item = &d.needs_you[0];
    assert_eq!(item.seq, first);
    assert_eq!(item.kind, PostKind::Breakage);
    assert_eq!(item.fold_key, "key:ci:main");
    let by: Vec<_> = item.attributions.iter().map(|a| a.author.as_str()).collect();
    assert_eq!(by, vec!["@team/agent-a", "@team/agent-b", "@team/agent-austin", "@team/agent-b"]);
    assert!(d.render(2000).text.contains("@team/agent-a +3 more"));
}

#[test]
fn posts_naming_the_same_single_subject_fold_and_show_the_newest_wording() {
    let feed = Feed::new();
    feed.post("agent-a", PostKind::Status, "Opened cmux#51930: team feed in NEXT", &[]);
    feed.post("agent-b", PostKind::Status, "manaflow-ai/cmux#51930 is green", &[]);
    feed.post(
        "agent-a",
        PostKind::Blocker,
        "https://github.com/manaflow-ai/cmux/pull/51930 conflicts, needs a rebase.",
        &["@leo"],
    );
    // Another subject, two subjects at once, and a bare number fold with none of them.
    feed.post("agent-a", PostKind::Status, "cmux#50003 is red", &[]);
    feed.post("agent-b", PostKind::Status, "cmux#51930 waits on cmux#50003", &[]);
    feed.post("agent-b", PostKind::Status, "see #51930", &[]);
    feed.post("agent-b", PostKind::Status, "c-a8d2c0a144 still open", &[]);
    feed.post("agent-a", PostKind::Status, "Reported on ask C-A8D2C0A144.", &[]);
    let d = feed.digest(&leo(), 0, &[]);
    assert_eq!((d.posts_seen, d.duplicates_folded), (8, 3));
    assert_eq!(d.needs_you.len(), 1);
    let item = &d.needs_you[0];
    assert_eq!(item.seq, 1, "the item keeps its first post's id");
    assert!(item.text.contains("needs a rebase"), "{}", item.text);
    assert_eq!(item.attributions.iter().map(|a| a.seq).collect::<Vec<_>>(), vec![1, 2, 3]);
    assert_eq!(
        digest::subject_key("fixed in leo-workspace#9176, thanks"),
        Some("subject:leo-workspace#9176".to_owned())
    );
    assert_eq!(digest::subject_key("see #12 and step #3"), None);
    assert_eq!(digest::subject_key("c#12x and issue#"), None);
}

#[test]
fn news_on_a_settled_subject_comes_back_up() {
    let feed = Feed::new();
    feed.post("agent-a", PostKind::Question, "Can I land cmux#49357?", &["@leo"]);
    let first = feed.digest(&leo(), 0, &[]);
    let prior = vec![first.action(&first.needs_you[0].id, Action::Answered, 1).unwrap()];
    // The same wording again stays settled.
    feed.post("agent-b", PostKind::Question, "can I land cmux#49357", &["@leo"]);
    let repeat = feed.digest(&leo(), first.to_seq, &prior);
    assert!(repeat.needs_you.is_empty());
    assert_eq!(repeat.rest[0].items[0].prior, Some(Action::Answered));
    // A new wording about the same subject is news, alone or folded with the old one.
    feed.post("agent-a", PostKind::Blocker, "cmux#49357 broke the base", &["@leo"]);
    let news = feed.digest(&leo(), repeat.to_seq, &prior);
    assert_eq!(news.needs_you.len(), 1);
    let whole = feed.digest(&leo(), 0, &prior);
    assert_eq!(whole.needs_you.len(), 1);
    assert_eq!((whole.posts_seen, whole.duplicates_folded), (3, 2));
    assert!(whole.needs_you[0].text.contains("broke the base"));
}

#[test]
fn a_feed_of_only_duplicates_is_one_item() {
    let feed = Feed::new();
    for _ in 0..50 {
        feed.post("agent-a", PostKind::Status, "Still waiting on the runner.", &[]);
    }
    let d = feed.digest(&leo(), 0, &[]);
    assert_eq!((d.posts_seen, d.duplicates_folded), (50, 49));
    assert_eq!(d.rest.len(), 1);
    assert_eq!((d.rest[0].posts, d.rest[0].items.len()), (50, 1));
    assert_eq!(d.rest[0].items[0].attributions.len(), 50);
}

#[test]
fn every_item_carries_thread_seq_and_source_link() {
    let feed = Feed::new();
    let seq = feed.post("agent-a", PostKind::Question, "ok?", &["@leo"]);
    let d = feed.digest(&leo(), 0, &[]);
    let item = &d.needs_you[0];
    assert_eq!((item.thread.as_str(), item.seq), ("topic:ci", seq));
    assert_eq!(item.link, format!("cmux://team/team/eng/topic%3Aci#{seq}"));
    assert_eq!(item.attributions[0].link, item.link);
    let json = d.to_json();
    let j = &json["needsYou"][0];
    assert_eq!(j["thread"], "topic:ci");
    assert_eq!(j["seq"], seq);
    assert_eq!(j["link"], item.link.as_str());
    assert_eq!(j["kind"], "question");
    assert_eq!(json["postsSeen"], 1);
}

#[test]
fn render_keeps_the_budget_and_says_how_many_items_it_cut() {
    let feed = Feed::new();
    for i in 0..30 {
        feed.post("agent-a", PostKind::Question, &format!("question number {i}"), &["@leo"]);
    }
    for i in 0..30 {
        feed.post("agent-b", PostKind::Fyi, &format!("fyi number {i}"), &[]);
    }
    let d = feed.digest(&leo(), 0, &[]);
    let full = d.render(usize::MAX);
    assert_eq!((full.cut, full.shown.len()), (0, 60));
    assert!(!full.text.contains("[cut"));
    for budget in [80, 300, 1000, 2500] {
        let r = d.render(budget);
        assert!(r.text.chars().count() <= budget, "{budget}: {}", r.text.chars().count());
        assert!(r.cut > 0);
        assert_eq!(r.cut + r.shown.len(), 60);
        assert!(r.text.ends_with(&format!("[cut {} items]", r.cut)), "{}", r.text);
        // Needs-you items are shown before anything else.
        assert!(r.shown.iter().take(30).all(|id| d.needs_you.iter().any(|e| &e.id == id)));
    }
}

#[test]
fn a_long_post_is_cut_in_the_item_and_its_rest_line() {
    let feed = Feed::new();
    feed.post("agent-a", PostKind::Fyi, &"y".repeat(400), &[]);
    let d = feed.digest(&leo(), 0, &[]);
    assert!(d.rest[0].items[0].text.ends_with(" [cut 120]"));
    assert!(d.render(10_000).text.contains(&format!("{} [cut 300]", "y".repeat(100))));
}

#[test]
fn an_item_addressed_to_two_people_is_in_both_digests_and_acted_on_separately() {
    let feed = Feed::new();
    feed.post("agent-a", PostKind::Question, "Who owns the relay?", &["@leo", "@austin"]);
    let leo_digest = feed.digest(&leo(), 0, &[]);
    let austin_digest = feed.digest(&austin(), 0, &[]);
    assert_eq!(leo_digest.needs_you.len(), 1);
    assert_eq!(austin_digest.needs_you.len(), 1);
    let id = leo_digest.needs_you[0].id.clone();
    assert_eq!(austin_digest.needs_you[0].id, id);

    let leo_agent = feed.agent("agent-leo", "leo");
    let dismissed = leo_digest.action(&id, Action::Dismissed, 10).unwrap();
    leo_agent.append_record(&PersonRecord::Acted(dismissed.clone())).unwrap();
    // Leo's dismissal is Leo's only.
    let austin_agent = feed.agent("agent-austin", "austin");
    assert_eq!(austin_agent.records("austin", 0).unwrap(), vec![]);
    let again = feed.digest(&austin(), 0, &[dismissed]);
    assert_eq!(again.needs_you.len(), 1);
    // And Austin's agent cannot write Leo's log.
    let forged = leo_digest.action(&id, Action::Answered, 11).unwrap();
    assert_eq!(
        austin_agent.append_record(&PersonRecord::Acted(forged)),
        Err(StoreError::Forbidden { space: SPACE.to_owned() })
    );
}

#[test]
fn a_settled_item_drops_to_rest_and_an_opened_one_is_marked() {
    let feed = Feed::new();
    feed.post_with("agent-a", PostKind::Question, "flaky test?", &["@leo"], Some("flake:t1"), &[]);
    feed.post("agent-a", PostKind::Question, "review please", &["@leo"]);
    let first = feed.digest(&leo(), 0, &[]);
    let prior = vec![
        first.action(&first.needs_you[0].id, Action::Answered, 1).unwrap(),
        first.action(&first.needs_you[1].id, Action::Opened, 2).unwrap(),
    ];
    let same = feed.digest(&leo(), 0, &prior);
    assert_eq!(same.needs_you.len(), 1);
    assert_eq!(same.needs_you[0].prior, Some(Action::Opened));
    assert!(same.render(1000).text.contains("[opened]"));
    assert_eq!(same.rest[0].items[0].prior, Some(Action::Answered));
    // A later duplicate of the answered item, from another agent, stays out of needs-you too.
    let head = first.to_seq;
    feed.post_with("agent-b", PostKind::Question, "is t1 flaky", &["@leo"], Some("flake:t1"), &[]);
    let later = feed.digest(&leo(), head, &prior);
    assert!(later.needs_you.is_empty());
    assert_eq!(later.rest[0].items[0].prior, Some(Action::Answered));
}

#[test]
fn stats_count_posts_duplicates_shown_and_acted_on() {
    let feed = Feed::new();
    feed.post("agent-a", PostKind::Question, "q1", &["@leo"]);
    feed.post("agent-b", PostKind::Question, "q1", &["@leo"]);
    feed.post("agent-a", PostKind::Fyi, "f1", &[]);
    feed.post("agent-a", PostKind::Fyi, "f2", &[]);
    let d = feed.digest(&leo(), 0, &[]);
    let r = d.render(10_000);
    let me = feed.agent("agent-leo", "leo");
    me.append_record(&PersonRecord::Shown(d.receipt(&r, 100))).unwrap();
    let q = d.needs_you[0].id.clone();
    let f = d.rest[0].items[0].id.clone();
    for record in [
        d.action(&q, Action::Opened, 101),
        d.action(&q, Action::Opened, 102),
        d.action(&q, Action::Answered, 103),
        d.action(&f, Action::Dismissed, 104),
    ] {
        me.append_record(&PersonRecord::Acted(record.unwrap())).unwrap();
    }
    // Leo himself reads his numbers too.
    let person = feed.store.client(acpmux_team_space::Author {
        kind: acpmux_team_space::AuthorKind::Person,
        id: "leo".to_owned(),
        team_address: None,
        on_behalf_of: None,
        session: None,
        host: None,
    });
    let s = stats(&person, "leo", 0).unwrap();
    assert_eq!(s.digests, 1);
    assert_eq!(s.posts_seen, 4);
    assert_eq!(s.duplicates_folded, 1);
    assert_eq!(s.items_shown, 3);
    assert_eq!(s.items_acted_on, 2);
    assert_eq!((s.opened, s.answered, s.dismissed, s.acted_unshown), (1, 1, 1, 0));
    // `since` drops what came before it: the receipt is gone, so the actions are unshown.
    let late = stats(&me, "leo", 103).unwrap();
    assert_eq!((late.digests, late.items_acted_on, late.acted_unshown), (0, 0, 2));
    // Nobody else reads Leo's numbers.
    assert!(matches!(
        stats(&feed.agent("agent-a", "someone"), "leo", 0),
        Err(StoreError::Forbidden { .. })
    ));
}

#[test]
fn items_cut_by_the_budget_are_not_counted_as_shown() {
    let feed = Feed::new();
    for i in 0..20 {
        feed.post("agent-a", PostKind::Question, &format!("q{i}"), &["@leo"]);
    }
    let d = feed.digest(&leo(), 0, &[]);
    let r = d.render(400);
    assert!(r.cut > 0);
    let receipt = d.receipt(&r, 1);
    assert_eq!(receipt.shown.len(), 20 - r.cut);
    assert_eq!(receipt.cut, r.cut);
}

#[test]
fn ten_thousand_events_read_in_bounded_pages() {
    let feed = Feed::new();
    for i in 0..10_000 {
        let to: &[&str] = if i % 1000 == 0 { &["@leo"] } else { &[] };
        let text = format!("status {}", i % 250);
        feed.post("agent-a", PostKind::Status, &text, to);
    }
    let calls = feed.store.feed_calls();
    let started = std::time::Instant::now();
    let d = feed.digest(&leo(), 0, &[]);
    let elapsed = started.elapsed();
    assert_eq!(feed.store.feed_calls() - calls, 10_000 / digest::READ_PAGE_LIMIT);
    assert_eq!((d.posts_seen, d.to_seq, d.head), (10_000, 10_000, 10_000));
    assert!(!d.behind);
    // 250 distinct texts; the ten addressed posts fold into texts that were already seen.
    assert_eq!(d.duplicates_folded, 10_000 - 250);
    assert!(d.affects_you.len() <= 10 && d.needs_you.is_empty());
    let r = d.render(4000);
    assert!(r.text.chars().count() <= 4000);
    assert_eq!(r.cut + r.shown.len(), 250);
    assert!(elapsed.as_secs() < 10, "{elapsed:?}");

    // A tighter event cap stops early and says so.
    let reader = feed.agent("agent-leo", "leo");
    let options = DigestOptions { max_events: 1200, ..DigestOptions::default() };
    let capped = digest::read(&reader, &leo(), SPACE, 0, &[], &options).unwrap();
    assert!(capped.behind);
    assert_eq!((capped.posts_seen, capped.to_seq), (1200, 1200));
    assert!(capped.render(10_000).text.contains("More posts wait past #1200"));
    let next = digest::read(&reader, &leo(), SPACE, capped.to_seq, &[], &options).unwrap();
    assert_eq!(next.from_seq, 1200);
    assert!(next.gaps.is_empty());
}

#[test]
fn a_cursor_behind_a_compacted_log_reports_the_gap() {
    let feed = Feed::new();
    for i in 0..10 {
        feed.post("agent-a", PostKind::Status, &format!("s{i}"), &[]);
    }
    feed.store.compact(SPACE, 6);
    let d = feed.digest(&leo(), 2, &[]);
    assert_eq!(d.gaps, vec![SeqGap { from: 3, to: 6 }]);
    assert_eq!((d.posts_seen, d.to_seq), (4, 10));
    assert!(d.render(1000).text.contains("4 posts are no longer in the feed"));

    // Everything past the cursor compacted: the cursor still moves to the head.
    feed.store.compact(SPACE, 10);
    let gone = feed.digest(&leo(), 2, &[]);
    assert_eq!(gone.gaps, vec![SeqGap { from: 3, to: 10 }]);
    assert_eq!((gone.posts_seen, gone.to_seq), (0, 10));

    // New posts after compaction carry on from the head, not from the events left.
    let seq = feed.post("agent-a", PostKind::Status, "after", &[]);
    assert_eq!(seq, 11);
    let caught_up = feed.digest(&leo(), 10, &[]);
    assert!(caught_up.gaps.is_empty());
    assert_eq!(caught_up.posts_seen, 1);
}

#[test]
fn a_tiny_budget_still_ends_with_the_cut_marker() {
    let feed = Feed::new();
    feed.post("agent-a", PostKind::Question, "q", &["@leo"]);
    let r = feed.digest(&leo(), 0, &[]).render(5);
    assert_eq!(r.shown.len(), 0);
    assert_eq!(r.text, "[cut 1 items]");
}

#[test]
fn the_json_form_round_trips_through_serde_json() {
    let feed = Feed::new();
    feed.post("agent-a", PostKind::Question, "q", &["@leo"]);
    feed.post("agent-a", PostKind::Win, "w", &[]);
    let d = feed.digest(&leo(), 0, &[]);
    let text = serde_json::to_string(&d.to_json()).unwrap();
    let back: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(back["rest"][0]["kind"], "win");
    assert_eq!(back["rest"][0]["posts"], 1);
    assert_eq!(back["needsYou"][0]["reasons"][0]["why"], "addressed");
}

#[test]
fn build_is_pure_and_skips_events_at_or_below_the_cursor_or_from_other_spaces() {
    let feed = Feed::new();
    feed.post("agent-a", PostKind::Question, "q1", &["@leo"]);
    feed.post("agent-a", PostKind::Question, "q2", &["@leo"]);
    let reader = feed.agent("agent-leo", "leo");
    let mut events = reader.feed(SPACE, 0, 10).unwrap().events;
    let mut stray = events[0].clone();
    stray.space = "team/other".to_owned();
    stray.seq = 3;
    events.push(stray);
    let window =
        digest::FeedWindow { space: SPACE, after: 1, head: 2, behind: false, events: &events };
    let d = digest::build(&leo(), &window, &[], &DigestOptions::default());
    assert_eq!(ids(&d.needs_you), vec![2]);
    assert_eq!((d.posts_seen, d.to_seq), (1, 2));
    assert!(d.gaps.is_empty());
}
