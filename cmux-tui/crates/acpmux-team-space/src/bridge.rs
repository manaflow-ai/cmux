//! A person's digest as a message for a channel outside the team feed (RFD 0064's bridge): email
//! or Slack, for people who are not on the feed yet.
//!
//! [`render`] is pure: a [`Digest`], the person it goes to and a [`Channel`] in, a [`Message`] out,
//! or `None` when the digest has nothing to say. It sends nothing; sending and the recipient list
//! come later.
//!
//! A message lists the raised items first (needs you, then affects you), each with its author,
//! its text as the digest cut it, and its source link. One line then counts the rest of the feed
//! and the duplicates folded into the items. Each channel shows at most a fixed number of items
//! ([`EMAIL_MAX_ITEMS`], [`SLACK_MAX_ITEMS`]) and says how many more there are.

use crate::digest::{Digest, DigestEntry};
use std::fmt::Write as _;

/// Where a message goes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Channel {
    /// A plain-text email.
    Email,
    /// A Slack message in mrkdwn.
    Slack,
}

/// One rendered message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Message {
    /// The email subject. For Slack it is the notification text shown beside the message.
    pub subject: String,
    pub body: String,
}

/// Raised items an email shows; the rest are counted.
pub const EMAIL_MAX_ITEMS: usize = 50;

/// Raised items a Slack message shows; the rest are counted.
pub const SLACK_MAX_ITEMS: usize = 10;

/// Characters an author list may take in one item line.
const AUTHOR_CHARS: usize = 80;

/// The counts a message states, so the subject and the body say the same numbers.
struct Counts {
    /// Raised items: needs you and affects you.
    raised: usize,
    /// Posts in the rest of the feed, duplicates included.
    more: usize,
    /// Posts folded into another item.
    duplicates: usize,
}

impl Counts {
    fn of(digest: &Digest) -> Self {
        Self {
            raised: digest.needs_you.len().saturating_add(digest.affects_you.len()),
            more: digest.rest.iter().map(|g| g.posts).sum(),
            duplicates: digest.duplicates_folded,
        }
    }

    fn summary(&self) -> String {
        format!("Team feed: {} for you, {} more", self.raised, self.more)
    }

    fn remainder_line(&self) -> String {
        format!(
            "{} more {} in the feed, {} {} folded.",
            self.more,
            plural(self.more, "post", "posts"),
            self.duplicates,
            plural(self.duplicates, "duplicate", "duplicates")
        )
    }
}

fn plural<'a>(n: usize, one: &'a str, many: &'a str) -> &'a str {
    if n == 1 { one } else { many }
}

/// The item's first poster, and how many more posted the same thing, at most [`AUTHOR_CHARS`].
fn author(entry: &DigestEntry) -> String {
    let first = entry.attributions.first().map(|a| a.author.as_str()).unwrap_or("someone");
    let first: String = first.chars().take(AUTHOR_CHARS).collect();
    match entry.attributions.len() {
        0 | 1 => first,
        n => format!("{first} +{} more", n.saturating_sub(1)),
    }
}

/// Slack mrkdwn's three control characters, escaped so a post cannot mention or link anyone.
fn slack_escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            _ => out.push(c),
        }
    }
    out
}

/// One line for a multi-line text: a message item stays one list entry.
fn one_line(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn raised(digest: &Digest) -> impl Iterator<Item = (&'static str, &DigestEntry)> {
    let needs = digest.needs_you.iter().map(|e| ("needs you", e));
    needs.chain(digest.affects_you.iter().map(|e| ("affects you", e)))
}

fn email(digest: &Digest, person: &str, counts: &Counts) -> Message {
    let mut body = String::new();
    let _ = writeln!(body, "Team feed {} for {}.", digest.space, person.trim());
    let _ = writeln!(body);
    for (section, entry) in raised(digest).take(EMAIL_MAX_ITEMS) {
        let _ = writeln!(
            body,
            "- [{section}] {} from {}: {}",
            entry.kind.as_str(),
            author(entry),
            one_line(&entry.text)
        );
        let _ = writeln!(body, "  {}", entry.link);
    }
    let hidden = counts.raised.saturating_sub(EMAIL_MAX_ITEMS);
    if hidden > 0 {
        let _ = writeln!(body, "- and {hidden} more for you");
    }
    if counts.raised > 0 {
        let _ = writeln!(body);
    }
    let _ = writeln!(body, "{}", counts.remainder_line());
    Message { subject: counts.summary(), body }
}

fn slack(digest: &Digest, mention: &str, counts: &Counts) -> Message {
    let mut body = String::new();
    let _ = writeln!(
        body,
        "{} team feed *{}*: {} for you, {} more",
        mention.trim(),
        slack_escape(&digest.space),
        counts.raised,
        counts.more
    );
    for (section, entry) in raised(digest).take(SLACK_MAX_ITEMS) {
        let _ = writeln!(
            body,
            "• _{section}_ {} from *{}*: {} <{}|#{}>",
            entry.kind.as_str(),
            slack_escape(&author(entry)),
            slack_escape(&one_line(&entry.text)),
            slack_escape(&entry.link),
            entry.seq
        );
    }
    let hidden = counts.raised.saturating_sub(SLACK_MAX_ITEMS);
    if hidden > 0 {
        let _ = writeln!(body, "• and {hidden} more for you");
    }
    let _ = writeln!(body, "{}", counts.remainder_line());
    Message { subject: counts.summary(), body }
}

/// `digest` as a message for `person` on `channel`, or `None` when it raises nothing and counts
/// nothing: an empty message is never sent. For email `person` is the name the body greets; for
/// Slack it is the mention the caller resolved (`<@U024BE7LH>`), put in the body once, as given.
pub fn render(digest: &Digest, person: &str, channel: Channel) -> Option<Message> {
    let counts = Counts::of(digest);
    if counts.raised == 0 && counts.more == 0 {
        return None;
    }
    Some(match channel {
        Channel::Email => email(digest, person, &counts),
        Channel::Slack => slack(digest, person, &counts),
    })
}
