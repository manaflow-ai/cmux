//! The Chief sees the chat as the person does (a455, Lawrence 2026-10-21:
//! "are you able to self reflect and see what i can see on the chat?"). The
//! Chief's view is its own log: what it said and did. Messages the host posts
//! in the Chief's name (a turn's done marker, the front desk's receipt, a
//! notice) never reach that log, so the Chief could not see a bubble such as
//! `optchat-2e448bc2-9041` that the person saw.
//!
//! Two things close that gap:
//! - the `transcript` tool: the last messages of the Chief conversation as the
//!   conversation daemon stores them, every author, with attachments,
//!   reactions, threads, and a flag on each message posted as the Chief that
//!   no Chief tool call wrote (`origin`);
//! - a self-check: such a message, when the person can see it, is logged as a
//!   note (`posted as you ...`) that the Chief's next turn reads.
//!
//! Who wrote a message posted as the Chief is read from its `client_msg_id`,
//! which every writer in this host sets: `send-` (the send tool), `reply-`
//! (the reply tool), `turn:optchat:` (a turn's closing text, or its done
//! marker when it has nothing to read), `voice:desk:` (the front desk) and
//! `notice:` (a host notice). Anything else came from outside this host's
//! tools (another install, an import, the app).

use cmux_conversation::{Message, Part, ReactionKind, Summary};

use super::Brain;

/// The most messages one `transcript` call returns.
pub use chief_kernel::tools::TRANSCRIPT_MAX;
/// The messages a `transcript` call returns when it names no count.
pub const TRANSCRIPT_DEFAULT: u32 = 20;
/// The answer's size cap: a longer one keeps its newest messages.
const TRANSCRIPT_BYTES: usize = 60_000;

/// Who wrote a message of the Chief conversation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Origin {
    /// Someone other than the Chief: the person, another agent or Chief.
    Other,
    /// The Chief, by one of its tool calls (`send`, `reply`) or its turn's
    /// closing text (`turn`).
    Chief(&'static str),
    /// The host, in the Chief's name, not the Chief's words: `done marker`,
    /// `front desk`, `approval relay`, `notice`, or `unknown` (a writer
    /// outside this host's tools).
    Host(&'static str),
}

impl Origin {
    /// The label the transcript shows: `you: send`, `host: done marker`.
    pub fn label(&self) -> Option<String> {
        match self {
            Origin::Other => None,
            Origin::Chief(how) => Some(format!("you: {how}")),
            Origin::Host(what) => Some(format!("host: {what}")),
        }
    }
}

/// Who wrote `message`, the Chief being participant `me`.
pub fn origin(message: &Message, me: &str) -> Origin {
    if message.author != me {
        return Origin::Other;
    }
    // The text fallback of a refused link-card reply keeps its key + `:text`.
    let key = message.client_msg_id.as_str();
    if key.starts_with("send-") {
        Origin::Chief("send")
    } else if key.starts_with("reply-") {
        Origin::Chief("reply")
    } else if key.starts_with("turn:optchat:") {
        if visible(message) {
            Origin::Chief("turn")
        } else {
            Origin::Host("done marker")
        }
    } else if crate::voice::of(key) == Some(crate::voice::DESK) {
        if key.contains(":approval:") {
            Origin::Host("approval relay")
        } else {
            Origin::Host("front desk")
        }
    } else if key.starts_with("notice:") {
        Origin::Host("notice")
    } else {
        Origin::Host("unknown")
    }
}

/// Whether a person sees `part` in Home: a work part shows only its preview
/// (its session id is no text, `WorkRef.shownText` in CmuxHomeCore).
fn part_visible(part: &Part) -> bool {
    match part {
        Part::Text { text, .. } => !text.trim().is_empty(),
        Part::Work { preview, .. } => preview.as_deref().is_some_and(|p| !p.trim().is_empty()),
        Part::Attachment { .. }
        | Part::LinkPreview { .. }
        | Part::Question(_)
        | Part::Unknown(_) => true,
    }
}

/// Whether a person sees `message` as a bubble in Home.
pub fn visible(message: &Message) -> bool {
    message.retracted_at.is_none() && message.parts.iter().any(part_visible)
}

/// The name `id` shows in Home, with its kind for anyone but the Chief.
pub(super) fn who(summary: Option<&Summary>, id: &str, me: &str) -> String {
    if id == me {
        return "Chief".to_owned();
    }
    summary
        .and_then(|s| s.participants.iter().find(|p| p.id == id))
        .map(|p| {
            let name = p.display_name.trim();
            let name = if name.is_empty() { id } else { name };
            format!("{name} ({id})")
        })
        .unwrap_or_else(|| id.to_owned())
}

fn bytes(n: u64) -> String {
    match n {
        n if n >= 1 << 20 => format!("{:.1} MB", n as f64 / (1 << 20) as f64),
        n if n >= 1 << 10 => format!("{:.0} KB", n as f64 / (1 << 10) as f64),
        n => format!("{n} B"),
    }
}

/// One part, as its own lines, indented.
fn part_lines(part: &Part, out: &mut Vec<String>) {
    match part {
        Part::Text { text, .. } => {
            for line in text.lines() {
                out.push(format!("  {line}"));
            }
            if text.is_empty() {
                out.push("  (empty text)".to_owned());
            }
        }
        Part::Work {
            session,
            host,
            status,
            preview,
        } => {
            let status = serde_json::to_value(status)
                .ok()
                .and_then(|v| v.as_str().map(str::to_owned))
                .unwrap_or_default();
            let on = host
                .as_deref()
                .map(|h| format!(" on {h}"))
                .unwrap_or_default();
            let shown = match preview.as_deref().map(str::trim).filter(|p| !p.is_empty()) {
                Some(p) => format!(": shows {p:?}"),
                // f3abfd2 (a427): Home draws no row for it; an older app drew the session id.
                None => {
                    " (hidden in Home since f3abfd2; an older app shows the session id as text)"
                        .to_owned()
                }
            };
            out.push(format!("  [work {session}{on} {status}{shown}]"));
        }
        Part::Attachment {
            hash,
            name,
            mime_type,
            byte_count,
            width,
            height,
            duration_ms,
            ..
        } => {
            let size = match (width, height) {
                (Some(w), Some(h)) => format!(" {w}x{h}"),
                _ => String::new(),
            };
            let length = duration_ms
                .map(|ms| format!(" {:.1}s", ms as f64 / 1000.0))
                .unwrap_or_default();
            let short: String = hash.chars().take(12).collect();
            out.push(format!(
                "  [attachment {name} {mime_type}{size}{length} {} sha256:{short}]",
                bytes(*byte_count)
            ));
        }
        Part::LinkPreview { url, title, .. } => {
            let title = title
                .as_deref()
                .map(|t| format!(" {t:?}"))
                .unwrap_or_default();
            out.push(format!("  [link card {url}{title}]"));
        }
        Part::Question(q) => {
            let asks: Vec<&str> = q.items.iter().map(|i| i.prompt.as_str()).collect();
            out.push(format!("  [question: {}]", asks.join(" / ")));
        }
        Part::Unknown(value) => {
            let kind = value.get("type").and_then(|t| t.as_str()).unwrap_or("?");
            out.push(format!("  [part of a type this host cannot read: {kind}]"));
        }
    }
}

/// The transcript block of `message`: a header line `#<seq> <date> <author>
/// [flags]`, then its parts and reactions, each line indented.
pub fn render(
    message: &Message,
    summary: Option<&Summary>,
    me: &str,
    line: Option<u64>,
    seq_of: &dyn Fn(&str) -> Option<u64>,
) -> String {
    let mut head = format!(
        "#{} {} {}",
        message.seq,
        message.created_at,
        who(summary, &message.author, me)
    );
    let mut flags: Vec<String> = Vec::new();
    if let Some(line) = line {
        flags.push(format!("line {line}"));
    }
    if let Some(label) = origin(message, me).label() {
        flags.push(label);
    }
    if message.author == me && !visible(message) {
        flags.push("hidden".to_owned());
    }
    let named = |id: &str| seq_of(id).map_or_else(|| id.to_owned(), |s| format!("#{s}"));
    if let Some(root) = &message.thread_root {
        flags.push(format!("thread of {}", named(root)));
    }
    if let Some(parent) = &message.reply_to
        && message.thread_root.as_deref() != Some(parent.message_id.as_str())
    {
        flags.push(format!("reply to {}", named(&parent.message_id)));
    }
    if !message.answers.is_empty() {
        let ids: Vec<String> = message.answers.iter().map(|a| named(a)).collect();
        flags.push(format!("answers {}", ids.join(" ")));
    }
    if let Some(remote) = &message.origin {
        let cmux_conversation::Origin::Remote { install } = remote;
        flags.push(format!("from install {install}"));
    }
    if message.edited_at.is_some() {
        flags.push("edited".to_owned());
    }
    if message.retracted_at.is_some() {
        flags.push("retracted".to_owned());
    }
    if !flags.is_empty() {
        head.push_str(&format!(" [{}]", flags.join("; ")));
    }
    let mut lines = vec![head];
    for part in &message.parts {
        part_lines(part, &mut lines);
    }
    if !message.reactions.is_empty() {
        let each: Vec<String> = message
            .reactions
            .iter()
            .map(|r| {
                let (label, _) = super::replies::reaction_label(&r.kind);
                let label = match &r.kind {
                    ReactionKind::Tapback(_) => label,
                    ReactionKind::Emoji(e) => e.clone(),
                };
                let by = if r.author == me {
                    "Chief".to_owned()
                } else {
                    who(summary, &r.author, me)
                };
                format!("{label} by {by}")
            })
            .collect();
        lines.push(format!("  reactions: {}", each.join(", ")));
    }
    lines.join("\n")
}

impl Brain {
    /// The `transcript` tool: the last `n` messages of the Chief
    /// conversation before seq `before` (None: the newest), as the daemon
    /// stores them, oldest first.
    pub(super) fn transcript(&mut self, n: u32, before: Option<u64>) -> Result<String, String> {
        let n = n.clamp(1, TRANSCRIPT_MAX);
        let conversation = self
            .state
            .conversation
            .clone()
            .ok_or("transcript: the conversation is not connected yet; try again")?;
        let daemon = self
            .daemon
            .as_mut()
            .ok_or("transcript: the conversation daemon is not connected; try again")?;
        let (summary, messages) = match before {
            Some(before) => {
                let summary = self.summary.clone();
                let messages = daemon
                    .history(&conversation, before, n)
                    .map_err(|e| format!("transcript: reading the conversation failed: {e}"))?;
                (summary, messages)
            }
            None => {
                let (summary, messages) = daemon
                    .snapshot(&conversation, n)
                    .map_err(|e| format!("transcript: reading the conversation failed: {e}"))?;
                (Some(summary), messages)
            }
        };
        let me = self.settings.membership.participant.clone();
        let seqs: std::collections::HashMap<&str, u64> =
            messages.iter().map(|m| (m.id.as_str(), m.seq)).collect();
        let seq_of = |id: &str| {
            seqs.get(id)
                .copied()
                .or_else(|| self.message_seqs.get(id).copied())
        };
        let mut blocks: Vec<String> = messages
            .iter()
            .map(|m| {
                let line = self.chat.logged_id(&format!("{conversation}#{}", m.seq));
                render(m, summary.as_ref(), &me, line, &seq_of)
            })
            .collect();
        // Over the cap: the newest messages stay.
        let mut cut = 0;
        while blocks.iter().map(|b| b.len() + 1).sum::<usize>() > TRANSCRIPT_BYTES
            && blocks.len() > 1
        {
            blocks.remove(0);
            cut += 1;
        }
        let first = messages.get(cut).map_or(0, |m| m.seq);
        let last = messages.last().map_or(0, |m| m.seq);
        let newest = summary.as_ref().map_or(last, |s| s.last_seq);
        let mut out = if blocks.is_empty() {
            "outcome: done. no messages there.".to_owned()
        } else {
            format!(
                "outcome: done. messages #{first} to #{last} of #{newest} in your conversation, oldest first, as the conversation daemon stores them and Home shows them. \"host: ...\" marks a message posted as you that no tool call of yours wrote; \"hidden\": Home draws no bubble for it."
            )
        };
        if cut > 0 {
            out.push_str(&format!(
                " The {cut} oldest did not fit; ask again with before={first}."
            ));
        } else if first > 1 && !blocks.is_empty() {
            out.push_str(&format!(" Older: before={first}."));
        }
        for block in blocks {
            out.push('\n');
            out.push_str(&block);
        }
        Ok(out)
    }

    /// The self-check: a message posted as the Chief that no Chief tool
    /// wrote and the person can see is logged as a note, which the next
    /// turn's delta carries. Its key names the message, so a replay logs it
    /// once.
    pub(super) fn note_host_post(&mut self, message: &Message) {
        let me = &self.settings.membership.participant;
        let Origin::Host(what) = origin(message, me) else {
            return;
        };
        if !visible(message) {
            return;
        }
        let first_line = cmux_chief::rules::message_text(message)
            .lines()
            .find(|l| !l.trim().is_empty())
            .unwrap_or("(no text: an attachment or card)")
            .chars()
            .take(160)
            .collect::<String>();
        let text = format!(
            "posted as you, not by your tools ({what}), message #{}: {first_line}",
            message.seq
        );
        let entry = optchat_host::NewMessage {
            key: Some(format!(
                "{}#{}:posted-as-you",
                message.conversation, message.seq
            )),
            ..optchat_host::NewMessage::new(optchat_core::Kind::Note, &text)
        };
        if let Err(e) = self.chat.append_with(&[entry], |_| Vec::new()) {
            (self.log)(&format!(
                "logging the message posted as the Chief #{} failed: {e}",
                message.seq
            ));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn chief(key: &str, parts: Vec<Part>) -> Message {
        serde_json::from_value(serde_json::json!({
            "id": "m", "conversation": "c", "seq": 7, "client_msg_id": key,
            "author": "agent_mux", "parts": parts, "created_at": "2026-10-22T04:20:21.486Z",
            "reactions": []
        }))
        .unwrap()
    }

    fn text(t: &str) -> Part {
        Part::Text {
            text: t.into(),
            runs: None,
        }
    }

    #[test]
    fn each_writer_of_a_chief_message_has_its_origin() {
        let marker = Part::Work {
            session: "optchat-2e448bc2-9041".into(),
            host: None,
            status: cmux_conversation::WorkStatus::Done,
            preview: None,
        };
        let cases = [
            ("send-c-t-00ff", vec![text("hi")], Origin::Chief("send")),
            (
                "send-c-t-00ff:text",
                vec![text("hi")],
                Origin::Chief("send"),
            ),
            ("reply-c-3-00ff", vec![text("hi")], Origin::Chief("reply")),
            (
                "turn:optchat:9:1",
                vec![text("done")],
                Origin::Chief("turn"),
            ),
            (
                "turn:optchat:9041:1",
                vec![marker],
                Origin::Host("done marker"),
            ),
            (
                "voice:desk:turn:optchat:4:17",
                vec![text("Got it.")],
                Origin::Host("front desk"),
            ),
            (
                "voice:desk:approval:p1",
                vec![text("Allow?")],
                Origin::Host("approval relay"),
            ),
            (
                "notice:optchat:compactor:1",
                vec![text("x")],
                Origin::Host("notice"),
            ),
            ("cmk_abc", vec![text("x")], Origin::Host("unknown")),
        ];
        for (key, parts, want) in cases {
            assert_eq!(origin(&chief(key, parts), "agent_mux"), want, "{key}");
        }
        let mut theirs = chief("cmk_abc", vec![text("x")]);
        theirs.author = "user_local".into();
        assert_eq!(origin(&theirs, "agent_mux"), Origin::Other);
    }

    #[test]
    fn the_9041_marker_renders_with_its_session_and_flags() {
        // The message as the daemon stored it (seq 1745, 2026-10-21 21:20 PDT).
        let stored: Message = serde_json::from_str(r#"{"id":"msg_01M5GXDBBEC5E52K5YJWJGNCWT","conversation":"conv_01M48Z7KT7N1A0EVSVXCZB5HZW","seq":1745,"client_msg_id":"turn:optchat:9041:202610212119084400700","author":"agent_mux","parts":[{"type":"work","session":"optchat-2e448bc2-9041","status":"done"}],"reply_to":{"message_id":"msg_01M5GHEZVBKM5Y91MHWZ317V50","part_index":0},"answers":["msg_01M5GXB40HZ122JBD2E6H3Q2V5","msg_01M5GHEZVBKM5Y91MHWZ317V50"],"thread_root":"msg_01M5GHEZVBKM5Y91MHWZ317V50","created_at":"2026-10-22T04:20:21.486Z","reactions":[]}"#).unwrap();
        let seq_of = |id: &str| (id == "msg_01M5GHEZVBKM5Y91MHWZ317V50").then_some(1700);
        let out = render(&stored, None, "agent_mux", None, &seq_of);
        assert!(
            out.starts_with("#1745 2026-10-22T04:20:21.486Z Chief ["),
            "{out}"
        );
        assert!(out.contains("host: done marker"), "{out}");
        assert!(out.contains("hidden"), "{out}");
        assert!(out.contains("thread of #1700"), "{out}");
        assert!(
            out.contains("[work optchat-2e448bc2-9041 done (hidden in Home"),
            "{out}"
        );
        assert!(!visible(&stored));
    }
}
