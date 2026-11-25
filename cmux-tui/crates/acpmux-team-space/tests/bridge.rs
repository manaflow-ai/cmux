//! A person's digest rendered for email and Slack, against the fake store: no empty messages,
//! raised items before the counted remainder, the item bounds, and counts that agree.

use acpmux_team_space::bridge::{self, Channel, EMAIL_MAX_ITEMS, SLACK_MAX_ITEMS};
use acpmux_team_space::digest;
use acpmux_team_space::fake::{FakeClient, FakeStore};
use acpmux_team_space::{Digest, DigestOptions, NewPost, Person, PostKind, TeamSpaceStore};

const SPACE: &str = "team/eng";
const MENTION: &str = "<@U024BE7LH>";

fn leo() -> Person {
    Person {
        id: "leo".to_owned(),
        handle: "@leo".to_owned(),
        agents: vec!["agent-leo".to_owned()],
        areas: vec!["cmux-tui/crates/acpmux/**".to_owned()],
    }
}

struct Feed {
    store: FakeStore,
    posted: std::cell::Cell<u64>,
}

impl Feed {
    fn new() -> Self {
        let store = FakeStore::new();
        for member in ["agent-a", "agent-b", "agent-leo"] {
            store.admit(SPACE, member);
        }
        Self { store, posted: std::cell::Cell::new(0) }
    }

    fn agent(&self, id: &str, person: &str) -> FakeClient {
        self.store.client(FakeClient::agent_author(id, &format!("@team/{id}"), person, None, None))
    }

    fn post(&self, by: &str, kind: PostKind, text: &str, to: &[&str]) -> u64 {
        let n = self.posted.get();
        self.posted.set(n + 1);
        self.agent(by, "someone")
            .post(&NewPost {
                space: SPACE.to_owned(),
                thread: "topic:ci".to_owned(),
                kind,
                text: text.to_owned(),
                to: to.iter().map(|s| (*s).to_owned()).collect(),
                idempotency_key: format!("{by}:{n}"),
                dedupe: None,
                areas: Vec::new(),
                reported_session: None,
                reported_host: None,
            })
            .unwrap()
            .seq
    }

    fn digest(&self) -> Digest {
        let reader = self.agent("agent-leo", "leo");
        digest::read(&reader, &leo(), SPACE, 0, &[], &DigestOptions::default()).unwrap()
    }
}

fn email(d: &Digest) -> bridge::Message {
    bridge::render(d, "Leo", Channel::Email).expect("an email")
}

fn slack(d: &Digest) -> bridge::Message {
    bridge::render(d, MENTION, Channel::Slack).expect("a Slack message")
}

fn position(body: &str, needle: &str) -> usize {
    body.find(needle).unwrap_or_else(|| panic!("{needle:?} not in {body}"))
}

#[test]
fn an_empty_digest_is_no_message() {
    let feed = Feed::new();
    let d = feed.digest();
    assert_eq!(d.posts_seen, 0);
    assert_eq!(bridge::render(&d, "Leo", Channel::Email), None);
    assert_eq!(bridge::render(&d, MENTION, Channel::Slack), None);

    // Only compacted seqs, nothing read: still nothing to send.
    feed.post("agent-a", PostKind::Status, "s1", &[]);
    feed.store.compact(SPACE, 1);
    let gone = feed.digest();
    assert_eq!((gone.posts_seen, gone.gaps.len()), (0, 1));
    assert_eq!(bridge::render(&gone, "Leo", Channel::Email), None);
    assert_eq!(bridge::render(&gone, MENTION, Channel::Slack), None);
}

#[test]
fn a_digest_with_only_the_rest_is_a_counted_message() {
    let feed = Feed::new();
    feed.post("agent-a", PostKind::Win, "shipped", &[]);
    feed.post("agent-b", PostKind::Win, "Shipped!", &[]);
    let d = feed.digest();
    let m = email(&d);
    assert_eq!(m.subject, "Team feed: 0 for you, 2 more");
    assert!(m.body.contains("2 more posts in the feed, 1 duplicate folded."), "{}", m.body);
    assert!(!m.body.contains("- ["), "{}", m.body);
    assert!(slack(&d).body.contains("2 more posts in the feed"));
}

#[test]
fn raised_items_come_before_the_remainder() {
    let feed = Feed::new();
    feed.post("agent-a", PostKind::Status, "rest one", &[]);
    feed.post("agent-a", PostKind::Fyi, "Renamed cmux-tui/crates/acpmux/src/lib.rs", &[]);
    feed.post("agent-b", PostKind::Question, "Can I land cmux#1?", &["@leo"]);
    feed.post("agent-b", PostKind::Status, "rest two", &[]);
    let d = feed.digest();
    assert_eq!((d.needs_you.len(), d.affects_you.len()), (1, 1));

    let m = email(&d);
    let needs = position(&m.body, "Can I land cmux#1?");
    let affects = position(&m.body, "Renamed cmux-tui/crates/acpmux/src/lib.rs");
    let remainder = position(&m.body, "2 more posts in the feed");
    assert!(needs < affects && affects < remainder, "{}", m.body);
    assert!(m.body.contains("[needs you] question from @team/agent-b: Can I land cmux#1?"));
    assert!(m.body.contains(&format!("  {}\n", d.needs_you[0].link)), "{}", m.body);
    assert!(!m.body.contains("rest one"), "rest items are counted, not listed");

    let s = slack(&d);
    let needs = position(&s.body, "Can I land cmux#1?");
    let affects = position(&s.body, "Renamed cmux-tui/crates/acpmux/src/lib.rs");
    let remainder = position(&s.body, "2 more posts in the feed");
    assert!(needs < affects && affects < remainder, "{}", s.body);
    let seq = d.needs_you[0].seq;
    assert!(s.body.contains(&format!("<{}|#{seq}>", d.needs_you[0].link)), "{}", s.body);
}

#[test]
fn the_item_bound_holds_with_an_and_n_more_line() {
    let feed = Feed::new();
    let total = EMAIL_MAX_ITEMS + 7;
    for i in 0..total {
        feed.post("agent-a", PostKind::Question, &format!("question number {i}"), &["@leo"]);
    }
    let d = feed.digest();
    assert_eq!(d.needs_you.len(), total);

    let s = slack(&d);
    let items = s.body.lines().filter(|l| l.starts_with("• _")).count();
    assert_eq!(items, SLACK_MAX_ITEMS, "{}", s.body);
    let more = format!("• and {} more for you", total - SLACK_MAX_ITEMS);
    assert!(s.body.contains(&more), "{}", s.body);
    assert!(position(&s.body, &more) < position(&s.body, "0 more posts in the feed"));
    assert!(s.body.contains(&format!("question number {} <", SLACK_MAX_ITEMS - 1)));
    assert!(!s.body.contains(&format!("question number {SLACK_MAX_ITEMS} <")));

    let e = email(&d);
    let items = e.body.lines().filter(|l| l.starts_with("- [")).count();
    assert_eq!(items, EMAIL_MAX_ITEMS, "{}", e.body);
    assert!(e.body.contains(&format!("- and {} more for you", total - EMAIL_MAX_ITEMS)));
    assert_eq!(e.subject, format!("Team feed: {total} for you, 0 more"));

    // Under the bound there is no "and N more" line.
    let small = Feed::new();
    small.post("agent-a", PostKind::Question, "only one", &["@leo"]);
    let one = small.digest();
    assert!(!slack(&one).body.contains("more for you"), "{}", slack(&one).body);
    assert!(!email(&one).body.contains("more for you"));
}

#[test]
fn the_email_subject_counts_match_the_body() {
    let feed = Feed::new();
    for i in 0..3 {
        feed.post("agent-b", PostKind::Question, &format!("q{i} for leo"), &["@leo"]);
    }
    for i in 0..10 {
        feed.post("agent-a", PostKind::Status, &format!("status {i}"), &[]);
    }
    feed.post("agent-b", PostKind::Status, "Status 0", &[]);
    feed.post("agent-b", PostKind::Status, "status 0!", &[]);
    let d = feed.digest();
    assert_eq!((d.posts_seen, d.duplicates_folded), (15, 2));

    let m = email(&d);
    assert_eq!(m.subject, "Team feed: 3 for you, 12 more");
    let items = m.body.lines().filter(|l| l.starts_with("- [")).count();
    assert_eq!(items, 3, "{}", m.body);
    assert!(m.body.contains("12 more posts in the feed, 2 duplicates folded."), "{}", m.body);
    // Slack states the same numbers.
    let s = slack(&d);
    assert_eq!(s.subject, m.subject);
    assert!(s.body.lines().next().unwrap().ends_with("3 for you, 12 more"), "{}", s.body);
    assert!(s.body.contains("12 more posts in the feed, 2 duplicates folded."));
}

#[test]
fn slack_text_has_the_mention_exactly_once_and_posts_cannot_add_one() {
    let feed = Feed::new();
    feed.post(
        "agent-a",
        PostKind::Question,
        &format!("hey {MENTION} look <!channel> & co"),
        &["@leo"],
    );
    feed.post("agent-b", PostKind::Status, &format!("cc {MENTION}"), &[]);
    let d = feed.digest();
    let s = slack(&d);
    assert_eq!(s.body.matches(MENTION).count(), 1, "{}", s.body);
    assert!(s.body.starts_with(MENTION), "{}", s.body);
    assert!(s.body.contains("hey &lt;@U024BE7LH&gt; look &lt;!channel&gt; &amp; co"), "{}", s.body);
    assert!(!s.body.contains("<!channel>"));
}

#[test]
fn a_multi_line_post_is_one_item_line_and_folded_posters_are_counted() {
    let feed = Feed::new();
    feed.post("agent-a", PostKind::Blocker, "runner gone\nsee logs", &["@leo"]);
    feed.post("agent-b", PostKind::Blocker, "Runner gone, see logs", &["@leo"]);
    let d = feed.digest();
    let e = email(&d);
    assert!(
        e.body.contains("[needs you] blocker from @team/agent-a +1 more: runner gone see logs\n"),
        "{}",
        e.body
    );
    let s = slack(&d);
    assert!(s.body.contains("from *@team/agent-a +1 more*: runner gone see logs <"), "{}", s.body);
}
