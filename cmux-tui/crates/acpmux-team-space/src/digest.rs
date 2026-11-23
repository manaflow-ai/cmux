//! A person's digest of a team space (RFD 0064): what needs them first, then what touches them
//! or their area, each with its source; everything else as counted one-liners, with duplicates
//! folded into one item that names every poster.
//!
//! [`build`] is pure: feed events after the person's cursor, the person, and their prior action
//! records in, a [`Digest`] out. [`read`] pages a [`TeamSpaceStore`] feed into [`build`].
//! [`Digest::render`] writes the plain text under a character budget with an explicit cut
//! marker; the [`Digest`] value serializes as the JSON form.
//!
//! The rules, in order, for each post:
//! - **Needs you**: a question or blocker addressed to the person or one of their agents, or any
//!   post that @mentions them or one of their agents in its text.
//! - **Affects you**: any other post addressed to them, or a post whose areas (or a path-like
//!   token in its text) match one of the person's area globs.
//! - **Rest**: everything else, including the person's own and their agents' posts, grouped by
//!   kind with a count.
//! - **Folding**: posts with the same dedupe key, or the same normalized text, are one item with
//!   one attribution per post. The item sits in the highest section any of its posts earns.
//! - **Settled**: an item whose fold key matches a prior `answered` or `dismissed` record of this
//!   person goes to rest; a prior `opened` stays where it is and is marked.

use crate::delivery::cut;
use crate::glob;
use crate::model::{Author, Event, PostKind};
use crate::record::{Action, ActionRecord, DigestReceipt};
use crate::store::{StoreError, TeamSpaceStore};
use serde::Serialize;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::fmt::Write as _;

/// The person a digest is for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Person {
    /// The person's id, as their agents' posts name it in `on_behalf_of`.
    pub id: String,
    /// The person's team handle (`@leo` or `leo`).
    pub handle: String,
    /// Their agents: ids or team addresses (`agent-7`, `@team/reviewer`).
    pub agents: Vec<String>,
    /// Areas they own, as globs over paths or labels ([`crate::glob`]).
    pub areas: Vec<String>,
}

/// Digest settings.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DigestOptions {
    /// Source links are `{link_base}/{space}/{thread}#{seq}`.
    pub link_base: String,
    /// At most this many events are read per digest by [`read`]; the rest wait for the next one.
    pub max_events: usize,
}

impl Default for DigestOptions {
    fn default() -> Self {
        Self { link_base: "cmux://team".to_owned(), max_events: 20_000 }
    }
}

/// Why an item is in front of the person.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(tag = "why", rename_all = "camelCase")]
pub enum Reason {
    /// The post's `to` names the person or one of their agents.
    Addressed { to: String },
    /// The post's text @mentions the person or one of their agents.
    Mentioned { name: String },
    /// The post touches an area the person owns.
    Area { area: String, matched: String },
}

/// One poster of a folded item.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Attribution {
    pub author: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub on_behalf_of: Option<String>,
    pub thread: String,
    pub post_id: String,
    pub seq: u64,
    pub link: String,
}

/// One digest item: a post, or several posts folded into one.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DigestEntry {
    /// `{space}/{post id}` of the item's first post. Action records name items by it.
    pub id: String,
    /// `key:{dedupe}` or `text:{normalized text}` of the first post.
    pub fold_key: String,
    pub space: String,
    pub thread: String,
    pub seq: u64,
    pub kind: PostKind,
    /// The first post's text, cut to [`crate::delivery::DIGEST_TEXT_CHARS`].
    pub text: String,
    /// Characters in the first post's whole text.
    pub chars: usize,
    pub link: String,
    pub attributions: Vec<Attribution>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub reasons: Vec<Reason>,
    /// The person's latest prior action on this item, if any.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub prior: Option<Action>,
}

/// The rest of the feed of one kind.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RestGroup {
    pub kind: PostKind,
    /// Posts in the group, duplicates included.
    pub posts: usize,
    pub items: Vec<DigestEntry>,
}

/// Seqs a reader's cursor passed over that the feed no longer holds (compacted, or withheld).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct SeqGap {
    /// First missing seq.
    pub from: u64,
    /// Last missing seq.
    pub to: u64,
}

impl SeqGap {
    pub fn len(&self) -> u64 {
        self.to - self.from + 1
    }

    pub fn is_empty(&self) -> bool {
        false
    }
}

/// One person's digest of one space.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Digest {
    pub person: String,
    pub handle: String,
    pub space: String,
    /// The cursor the digest read after.
    pub from_seq: u64,
    /// The new cursor: the last seq the digest covered.
    pub to_seq: u64,
    /// The space's head when read.
    pub head: u64,
    /// More events wait past `to_seq` than one digest reads.
    pub behind: bool,
    pub posts_seen: usize,
    pub duplicates_folded: usize,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub gaps: Vec<SeqGap>,
    pub needs_you: Vec<DigestEntry>,
    pub affects_you: Vec<DigestEntry>,
    pub rest: Vec<RestGroup>,
}

/// A digest rendered as plain text, and what it showed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rendered {
    pub text: String,
    /// Ids of the items the text shows.
    pub shown: Vec<String>,
    /// Items the budget cut.
    pub cut: usize,
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Section {
    Rest,
    Affects,
    Needs,
}

struct Group {
    entry: DigestEntry,
    section: Section,
    fold_keys: Vec<String>,
}

/// Lowercase, alphanumerics only, single spaces: "Build is RED on main!" and "build is red on
/// main" fold.
pub fn normalize(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut space = false;
    for c in text.chars() {
        if c.is_alphanumeric() {
            if space && !out.is_empty() {
                out.push(' ');
            }
            space = false;
            out.extend(c.to_lowercase());
        } else {
            space = true;
        }
    }
    out
}

fn fold_keys(event: &Event) -> Vec<String> {
    let mut keys = Vec::with_capacity(2);
    if let Some(key) = event.dedupe.as_deref().map(str::trim).filter(|k| !k.is_empty()) {
        keys.push(format!("key:{key}"));
    }
    keys.push(format!("text:{}", normalize(&event.text)));
    keys
}

fn name(s: &str) -> String {
    s.trim().trim_start_matches('@').to_lowercase()
}

fn encode(segment: &str) -> String {
    let mut out = String::with_capacity(segment.len());
    for b in segment.bytes() {
        if b.is_ascii_alphanumeric() || b"-._~/".contains(&b) {
            out.push(b as char);
        } else {
            let _ = write!(out, "%{b:02X}");
        }
    }
    out
}

fn link(base: &str, event: &Event) -> String {
    format!(
        "{}/{}/{}#{}",
        base.trim_end_matches('/'),
        encode(&event.space),
        encode(&event.thread),
        event.seq
    )
}

fn author_name(author: &Author) -> String {
    author.team_address.clone().unwrap_or_else(|| author.id.clone())
}

/// Tokens in a post's text that could name a path or label.
fn text_tokens(text: &str) -> impl Iterator<Item = &str> {
    text.split_whitespace()
        .map(|t| t.trim_matches(|c: char| "`'\"()[]{}<>,.;:!?".contains(c)))
        .filter(|t| !t.is_empty())
}

struct Matcher<'a> {
    person: &'a Person,
    names: HashSet<String>,
}

impl<'a> Matcher<'a> {
    fn new(person: &'a Person) -> Self {
        let mut names: HashSet<String> = person.agents.iter().map(|a| name(a)).collect();
        names.insert(name(&person.handle));
        names.insert(name(&person.id));
        names.retain(|n| !n.is_empty());
        Self { person, names }
    }

    fn own(&self, author: &Author) -> bool {
        let id = name(&author.id);
        author.on_behalf_of.as_deref().is_some_and(|p| name(p) == name(&self.person.id))
            || self.names.contains(&id)
            || author.team_address.as_deref().is_some_and(|a| self.names.contains(&name(a)))
    }

    fn reasons(&self, event: &Event) -> Vec<Reason> {
        let mut reasons = Vec::new();
        for to in &event.to {
            if self.names.contains(&name(to)) {
                reasons.push(Reason::Addressed { to: to.clone() });
            }
        }
        for token in text_tokens(&event.text) {
            if token.starts_with('@') && self.names.contains(&name(token)) {
                let mention = Reason::Mentioned { name: token.to_owned() };
                if !reasons.contains(&mention) {
                    reasons.push(mention);
                }
            }
        }
        for area in &self.person.areas {
            let hit = event
                .areas
                .iter()
                .map(String::as_str)
                .chain(text_tokens(&event.text))
                .find(|candidate| glob::matches(area, candidate));
            if let Some(matched) = hit {
                reasons.push(Reason::Area { area: area.clone(), matched: matched.to_owned() });
            }
        }
        reasons
    }
}

fn section(kind: PostKind, reasons: &[Reason]) -> Section {
    let addressed = reasons.iter().any(|r| matches!(r, Reason::Addressed { .. }));
    let mentioned = reasons.iter().any(|r| matches!(r, Reason::Mentioned { .. }));
    if mentioned || (addressed && matches!(kind, PostKind::Question | PostKind::Blocker)) {
        Section::Needs
    } else if reasons.is_empty() {
        Section::Rest
    } else {
        Section::Affects
    }
}

/// What a reader got from one space's feed: the events after `after`, oldest first.
#[derive(Debug, Clone, Copy)]
pub struct FeedWindow<'a> {
    pub space: &'a str,
    /// The person's cursor.
    pub after: u64,
    /// The space's head as the store reported it.
    pub head: u64,
    /// The reader stopped before `head` on purpose (its event cap), so seqs past the last event
    /// are not gaps.
    pub behind: bool,
    pub events: &'a [Event],
}

/// Build `person`'s digest of one feed window. `prior` is the person's action records (others'
/// records and other spaces' are ignored).
pub fn build(
    person: &Person,
    window: &FeedWindow<'_>,
    prior: &[ActionRecord],
    options: &DigestOptions,
) -> Digest {
    let FeedWindow { space, after, head, behind, events } = *window;
    let matcher = Matcher::new(person);
    let mut latest: HashMap<&str, Action> = HashMap::new();
    let mut settled: HashMap<&str, Action> = HashMap::new();
    let mut prior_sorted: Vec<&ActionRecord> =
        prior.iter().filter(|r| r.person == person.id && r.space == space).collect();
    prior_sorted.sort_by_key(|r| r.at);
    for record in prior_sorted {
        latest.insert(record.item.as_str(), record.action);
        if record.action.settles() {
            settled.insert(record.fold_key.as_str(), record.action);
        }
    }

    let mut groups: Vec<Group> = Vec::new();
    let mut by_key: HashMap<String, usize> = HashMap::new();
    let mut gaps = Vec::new();
    let mut cursor = after;
    let mut posts_seen = 0;
    for event in events {
        if event.seq <= cursor || event.space != space {
            continue;
        }
        if event.seq > cursor + 1 {
            gaps.push(SeqGap { from: cursor + 1, to: event.seq - 1 });
        }
        cursor = event.seq;
        posts_seen += 1;

        let keys = fold_keys(event);
        let reasons = if matcher.own(&event.author) { Vec::new() } else { matcher.reasons(event) };
        let this_section = section(event.kind, &reasons);
        let source = link(&options.link_base, event);
        let attribution = Attribution {
            author: author_name(&event.author),
            on_behalf_of: event.author.on_behalf_of.clone(),
            thread: event.thread.clone(),
            post_id: event.post_id.clone(),
            seq: event.seq,
            link: source.clone(),
        };
        let index = match keys.iter().find_map(|k| by_key.get(k).copied()) {
            Some(index) => {
                let group = &mut groups[index];
                group.entry.attributions.push(attribution);
                for reason in reasons {
                    if !group.entry.reasons.contains(&reason) {
                        group.entry.reasons.push(reason);
                    }
                }
                group.section = group.section.max(this_section);
                for k in &keys {
                    if !group.fold_keys.contains(k) {
                        group.fold_keys.push(k.clone());
                    }
                }
                index
            }
            None => {
                let id = format!("{space}/{}", event.post_id);
                let prior_action = latest.get(id.as_str()).copied();
                groups.push(Group {
                    entry: DigestEntry {
                        id,
                        fold_key: keys[0].clone(),
                        space: space.to_owned(),
                        thread: event.thread.clone(),
                        seq: event.seq,
                        kind: event.kind,
                        text: cut(&event.text, crate::delivery::DIGEST_TEXT_CHARS),
                        chars: event.text.chars().count(),
                        link: source,
                        attributions: vec![attribution],
                        reasons,
                        prior: prior_action,
                    },
                    section: this_section,
                    fold_keys: keys.clone(),
                });
                groups.len() - 1
            }
        };
        for k in keys {
            by_key.entry(k).or_insert(index);
        }
    }
    if !behind && head > cursor {
        // The store says the space reaches `head` but returned nothing past `cursor`: those seqs
        // are gone from the feed.
        gaps.push(SeqGap { from: cursor + 1, to: head });
    }

    let duplicates_folded = posts_seen - groups.len();
    let mut needs_you = Vec::new();
    let mut affects_you = Vec::new();
    let mut rest: BTreeMap<PostKind, RestGroup> = BTreeMap::new();
    for mut group in groups {
        if let Some(action) = group.fold_keys.iter().find_map(|k| settled.get(k.as_str())) {
            group.entry.prior = Some(*action);
            group.section = Section::Rest;
        }
        match group.section {
            Section::Needs => needs_you.push(group.entry),
            Section::Affects => affects_you.push(group.entry),
            Section::Rest => {
                let slot = rest.entry(group.entry.kind).or_insert_with(|| RestGroup {
                    kind: group.entry.kind,
                    posts: 0,
                    items: Vec::new(),
                });
                slot.posts += group.entry.attributions.len();
                slot.items.push(group.entry);
            }
        }
    }
    let mut rest: Vec<RestGroup> = rest.into_values().collect();
    rest.sort_by(|a, b| b.posts.cmp(&a.posts).then(a.kind.cmp(&b.kind)));

    Digest {
        person: person.id.clone(),
        handle: person.handle.clone(),
        space: space.to_owned(),
        from_seq: after,
        to_seq: cursor.max(if behind { cursor } else { head.max(after) }),
        head,
        behind,
        posts_seen,
        duplicates_folded,
        gaps,
        needs_you,
        affects_you,
        rest,
    }
}

/// Events asked for per feed page by [`read`].
pub const READ_PAGE_LIMIT: usize = 500;

/// Read `space` after `after` from `store` (at most `options.max_events` events) and build
/// `person`'s digest of it.
pub fn read(
    store: &dyn TeamSpaceStore,
    person: &Person,
    space: &str,
    after: u64,
    prior: &[ActionRecord],
    options: &DigestOptions,
) -> Result<Digest, StoreError> {
    let mut events = Vec::new();
    let mut cursor = after;
    let mut head;
    loop {
        let want = READ_PAGE_LIMIT.min(options.max_events - events.len());
        let page = store.feed(space, cursor, want)?;
        head = page.head;
        let before = cursor;
        for event in page.events {
            if event.seq > cursor {
                cursor = event.seq;
                events.push(event);
            }
        }
        if cursor >= head || cursor == before || events.len() >= options.max_events {
            break;
        }
    }
    let behind = cursor < head && events.len() >= options.max_events;
    let window = FeedWindow { space, after, head, behind, events: &events };
    Ok(build(person, &window, prior, options))
}

/// One-line text of a rest item.
pub const REST_LINE_CHARS: usize = 100;

fn who(entry: &DigestEntry) -> String {
    let first = &entry.attributions[0].author;
    match entry.attributions.len() {
        1 => first.clone(),
        n => format!("{first} +{} more", n - 1),
    }
}

fn reasons_text(reasons: &[Reason]) -> String {
    let parts: Vec<String> = reasons
        .iter()
        .map(|r| match r {
            Reason::Addressed { to } => format!("to {to}"),
            Reason::Mentioned { name } => format!("mentions {name}"),
            Reason::Area { area, matched } => format!("{matched} in {area}"),
        })
        .collect();
    parts.join("; ")
}

/// The first line of the item's text, at most [`REST_LINE_CHARS`], with a cut marker counting
/// against the whole post.
fn one_line(entry: &DigestEntry) -> String {
    let line = entry.text.lines().next().unwrap_or("");
    let kept: String = line.chars().take(REST_LINE_CHARS).collect();
    let kept_chars = kept.chars().count();
    if kept_chars >= entry.chars {
        return kept;
    }
    // The item's text is cut at DIGEST_TEXT_CHARS, past REST_LINE_CHARS, so `kept` never holds
    // the item's own cut marker.
    format!("{kept} [cut {}]", entry.chars - kept_chars)
}

fn item_line(entry: &DigestEntry, full: bool) -> String {
    let mut line = if full {
        format!("- {} #{} {}: {}", entry.kind.as_str(), entry.seq, who(entry), entry.text)
    } else {
        format!("  - #{} {}: {}", entry.seq, who(entry), one_line(entry))
    };
    if full && !entry.reasons.is_empty() {
        let _ = write!(line, " ({})", reasons_text(&entry.reasons));
    }
    if let Some(action) = entry.prior {
        let _ = write!(line, " [{}]", action.as_str());
    }
    let _ = writeln!(line, " {}", entry.link);
    line
}

enum Line<'a> {
    Fixed(String),
    Item(&'a DigestEntry, String),
}

impl Digest {
    /// Every item, needs-you first, then affects-you, then rest in group order.
    pub fn items(&self) -> impl Iterator<Item = &DigestEntry> {
        self.needs_you
            .iter()
            .chain(&self.affects_you)
            .chain(self.rest.iter().flat_map(|g| &g.items))
    }

    pub fn item(&self, id: &str) -> Option<&DigestEntry> {
        self.items().find(|e| e.id == id)
    }

    /// The JSON form.
    pub fn to_json(&self) -> serde_json::Value {
        serde_json::to_value(self).unwrap_or(serde_json::Value::Null)
    }

    fn lines(&self) -> Vec<Line<'_>> {
        let mut lines = Vec::new();
        let range = if self.posts_seen == 0 {
            format!("no new posts after #{}", self.from_seq)
        } else {
            format!(
                "{} posts after #{} through #{}, {} duplicates folded",
                self.posts_seen, self.from_seq, self.to_seq, self.duplicates_folded
            )
        };
        lines
            .push(Line::Fixed(format!("Team feed {} for {}: {range}.\n", self.space, self.handle)));
        let missed: u64 = self.gaps.iter().map(SeqGap::len).sum();
        if missed > 0 {
            lines.push(Line::Fixed(format!(
                "{missed} posts are no longer in the feed (compacted) and are not in this digest.\n"
            )));
        }
        if self.behind {
            lines.push(Line::Fixed(format!(
                "More posts wait past #{}; the next digest starts there.\n",
                self.to_seq
            )));
        }
        for (title, entries) in [("Needs you", &self.needs_you), ("Affects you", &self.affects_you)]
        {
            if entries.is_empty() {
                continue;
            }
            lines.push(Line::Fixed(format!("{title} ({}):\n", entries.len())));
            for entry in entries {
                lines.push(Line::Item(entry, item_line(entry, true)));
            }
        }
        if !self.rest.is_empty() {
            let posts: usize = self.rest.iter().map(|g| g.posts).sum();
            lines.push(Line::Fixed(format!("Everything else ({posts} posts):\n")));
            for group in &self.rest {
                lines.push(Line::Fixed(format!(
                    "  {} ({} posts, {} items):\n",
                    group.kind.as_str(),
                    group.posts,
                    group.items.len()
                )));
                for entry in &group.items {
                    lines.push(Line::Item(entry, item_line(entry, false)));
                }
            }
        }
        lines
    }

    /// The plain-text digest in at most `budget` characters. When items do not fit, the text
    /// ends with `[cut N items]`, and `shown` lists only the items in the text. A budget smaller
    /// than the header and the cut marker still gets the marker.
    pub fn render(&self, budget: usize) -> Rendered {
        let lines = self.lines();
        let total_items = lines.iter().filter(|l| matches!(l, Line::Item(..))).count();
        let full: usize = lines
            .iter()
            .map(|l| match l {
                Line::Fixed(s) | Line::Item(_, s) => s.chars().count(),
            })
            .sum();
        let reserve = if full <= budget { 0 } else { format!("[cut {total_items} items]").len() };
        let mut text = String::new();
        let mut used = 0;
        let mut shown = Vec::new();
        let mut stopped = false;
        for line in &lines {
            let s = match line {
                Line::Fixed(s) | Line::Item(_, s) => s,
            };
            let len = s.chars().count();
            if stopped || used + len + reserve > budget {
                stopped = true;
                continue;
            }
            used += len;
            text.push_str(s);
            if let Line::Item(entry, _) = line {
                shown.push(entry.id.clone());
            }
        }
        let cut = total_items - shown.len();
        if cut > 0 {
            let _ = write!(text, "[cut {cut} items]");
        } else if stopped {
            // Only fixed lines were left out; still say the text is short.
            text.push_str("[cut 0 items]");
        }
        Rendered { text, shown, cut }
    }

    /// The receipt to append when `rendered` is shown to the person at `at`.
    pub fn receipt(&self, rendered: &Rendered, at: u64) -> DigestReceipt {
        DigestReceipt {
            person: self.person.clone(),
            space: self.space.clone(),
            from_seq: self.from_seq,
            to_seq: self.to_seq,
            posts_seen: self.posts_seen,
            duplicates_folded: self.duplicates_folded,
            shown: rendered.shown.clone(),
            cut: rendered.cut,
            at,
        }
    }

    /// The action record for the person doing `action` on item `id` at `at`, or `None` for an
    /// id this digest does not hold.
    pub fn action(&self, id: &str, action: Action, at: u64) -> Option<ActionRecord> {
        let entry = self.item(id)?;
        Some(ActionRecord {
            person: self.person.clone(),
            space: self.space.clone(),
            item: entry.id.clone(),
            fold_key: entry.fold_key.clone(),
            action,
            at,
        })
    }
}
