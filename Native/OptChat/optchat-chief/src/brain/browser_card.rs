//! The live browser card (issue 25830): while a turn drives a browser or a
//! computer, its conversation shows one `card` part with the step it is on,
//! the latest screenshot and what "Open browser" opens. The card is one
//! message per turn, posted at the first browser step and edited as the
//! steps go; the turn's end edits it once more with `live: false`.
//!
//! It is read from the run steps the brain already appends
//! (drafts.rs `turn_run`): a shell call of `cmux browser`, `cua-driver` or
//! the Cloud `cua.sh` helper, or an MCP browser or computer tool. A
//! screenshot is the newest picture of the turn since the card began: a tool
//! call's image, or the file a `cmux browser … screenshot --out FILE` wrote.

use cmux_conversation::{Card, CardImage, CardSurface, MAX_CARD_STEP_CHARS, Op, Part, PartRef};

use crate::state::BrowserCard;
use serde_json::{Value, json};

use super::Brain;

/// Largest screenshot file read from a `--out` path.
const MAX_SCREENSHOT_BYTES: u64 = cmux_conversation::MAX_CARD_IMAGE_BYTES;

/// What a run step tells the card: its surface, target and step line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct BrowserStep {
    pub surface: CardSurface,
    pub target: Option<String>,
    pub step: String,
    pub url: Option<String>,
    /// `cmux browser … screenshot --out FILE`: the file, once the call is done.
    pub screenshot: Option<String>,
}

/// The browser or computer step a run step is, if it is one.
pub(crate) fn browser_step(step: &Value) -> Option<BrowserStep> {
    let tool = step.get("tool")?;
    let name = tool.get("name").and_then(Value::as_str).unwrap_or_default();
    let input = tool.get("input");
    let command = input
        .and_then(|i| i.get("command"))
        .and_then(|c| match c {
            Value::String(s) => Some(s.clone()),
            Value::Array(items) => Some(
                items
                    .iter()
                    .filter_map(Value::as_str)
                    .collect::<Vec<_>>()
                    .join(" "),
            ),
            _ => None,
        })
        .unwrap_or_default();
    let lower_name = name.to_ascii_lowercase();
    let described = input
        .and_then(|i| i.get("description"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|d| !d.is_empty())
        .map(str::to_owned);
    let done = step.get("status").and_then(Value::as_str) == Some("done");
    let (surface, target, verb_line, url, screenshot) = if let Some(at) = command.find("cmux browser")
    {
        let words: Vec<&str> = command[at..].split_whitespace().collect();
        // `cmux browser right <verb> …` or `cmux browser page <verb> …`.
        let verb = words.get(3).copied().unwrap_or_default();
        let url = words
            .iter()
            .find(|w| w.starts_with("https://") || w.starts_with("http://"))
            .map(|w| w.trim_matches(['"', '\'']).to_owned())
            .filter(|u| cmux_conversation::valid_link_url(u));
        let screenshot = (verb == "screenshot" && done)
            .then(|| out_path(&words))
            .flatten();
        let target = (words.get(2) == Some(&"right")).then(|| "browser:right".to_owned());
        (
            CardSurface::Browser,
            target,
            browser_verb_line(verb, url.as_deref()),
            url,
            screenshot,
        )
    } else if command.contains("cua-driver") || command.contains("cua.sh") {
        (
            CardSurface::Computer,
            machine_target(&command),
            "Using the computer".to_owned(),
            None,
            None,
        )
    } else if lower_name.contains("computer") {
        (CardSurface::Computer, None, "Using the computer".to_owned(), None, None)
    } else if lower_name.contains("browser") {
        (CardSurface::Browser, None, "Using the browser".to_owned(), None, None)
    } else {
        return None;
    };
    let step: String = described
        .unwrap_or(verb_line)
        .chars()
        .filter(|c| !c.is_control())
        .take(MAX_CARD_STEP_CHARS)
        .collect();
    Some(BrowserStep {
        surface,
        target,
        step: step.trim_end_matches('.').trim().to_owned(),
        url,
        screenshot,
    })
}

/// The step line of a `cmux browser` verb when the call says nothing itself.
fn browser_verb_line(verb: &str, url: Option<&str>) -> String {
    let host = url
        .and_then(|u| u.split("://").nth(1))
        .and_then(|rest| rest.split(['/', '?', '#']).next())
        .unwrap_or_default();
    match verb {
        "open" | "navigate" | "goto" if !host.is_empty() => format!("Opening {host}"),
        "open" | "navigate" | "goto" => "Opening a page".to_owned(),
        "click" | "press" | "hover" => "Clicking on the page".to_owned(),
        "fill" | "type" | "select" => "Typing on the page".to_owned(),
        "fill-login" => "Signing in".to_owned(),
        "screenshot" => "Taking a screenshot".to_owned(),
        "snapshot" | "text" | "state" | "value" => "Reading the page".to_owned(),
        "scroll" => "Scrolling the page".to_owned(),
        "wait" => "Waiting for the page".to_owned(),
        "back" => "Going back".to_owned(),
        _ => "Using the browser".to_owned(),
    }
}

/// Queues `state`'s card as it is now: its first post (or a change to the
/// queued one), else an edit once the owner gave its id; a change while the
/// first post is in flight waits as `unsent`. Nothing is flushed here.
fn queue_card(state: &mut crate::state::HostState) {
    let Some(card) = state.browser_card.as_mut().filter(|c| !c.refused) else {
        return;
    };
    let parts = vec![Part::Card(card.card.clone())];
    let conversation = card.conversation.clone();
    let outbox = &mut state.outbox;
    match card.message_id.clone() {
        Some(message_id) => {
            outbox.retain(|e| {
                e.attempted
                    || !matches!(&e.op, Op::MessageEdit { message_id: id, .. } if *id == message_id)
            });
            outbox.push(edit_entry(card));
        }
        None => {
            if let Some(queued) = outbox.iter_mut().find(|e| e.idempotency_key == card.key) {
                if queued.attempted {
                    card.unsent = true;
                    return;
                }
                if let Op::MessageSend { parts: sent, .. } = &mut queued.op {
                    *sent = parts;
                }
                queued.plain_text = Some(card.card.text());
            } else {
                let mut entry = super::op_entry(
                    conversation,
                    &card.key,
                    Op::MessageSend {
                        client_msg_id: card.key.clone(),
                        parts,
                        reply_to: None,
                        answers: Vec::new(),
                        answers_pending: Vec::new(),
                        thread_root: None,
                    },
                );
                if let (
                    Some((root, parent)),
                    Op::MessageSend {
                        reply_to,
                        thread_root,
                        ..
                    },
                ) = (&card.thread, &mut entry.op)
                {
                    *reply_to = Some(PartRef {
                        message_id: parent.clone(),
                        part_index: 0,
                    });
                    *thread_root = Some(root.clone());
                }
                entry.plain_text = Some(card.card.text());
                outbox.push(entry);
            }
        }
    }
}


/// A restart found the pending turn cut off: its card stops being live.
pub(super) fn end_on_recover(state: &mut crate::state::HostState) {
    if let Some(card) = state.browser_card.as_mut()
        && let Card::Browser { live, .. } = &mut card.card
        && *live
    {
        *live = false;
        queue_card(state);
    }
}

/// Whether `key` is a browser card's (`{turn}:browser`, its edits and its
/// text): an aside, never the turn's reply.
pub(crate) fn is_card_key(key: &str) -> bool {
    key.ends_with(":browser") || key.contains(":browser:")
}

/// The edit that shows `card` as it is now (its message id known).
fn edit_entry(card: &mut BrowserCard) -> crate::state::OutboxEntry {
    card.edits += 1;
    let key = format!("{}:e{}", card.key, card.edits);
    super::op_entry(
        card.conversation.clone(),
        &key,
        Op::MessageEdit {
            message_id: card.message_id.clone().unwrap_or_default(),
            parts: vec![Part::Card(card.card.clone())],
        },
    )
}

/// `--out FILE` or `--out=FILE` of a command's words.
fn out_path(words: &[&str]) -> Option<String> {
    let path = words.iter().enumerate().find_map(|(i, w)| {
        if *w == "--out" {
            words.get(i + 1).map(|p| (*p).to_owned())
        } else {
            w.strip_prefix("--out=").map(str::to_owned)
        }
    })?;
    let path = path.trim_matches(['"', '\'']).to_owned();
    (!path.is_empty()).then_some(path)
}

/// `machine:<id>` named in a Cloud command (`cmux cloud exec --target machine:<id> …`).
fn machine_target(command: &str) -> Option<String> {
    let at = command.find("machine:")?;
    let id: String = command[at + "machine:".len()..]
        .chars()
        .take_while(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-'))
        .collect();
    let target = format!("machine:{id}");
    cmux_conversation::valid_card_target(&target).then_some(target)
}

/// A run attachment (drafts.rs `upload_image`) as a card screenshot, when it is one.
fn card_image(attachment: &Value) -> Option<CardImage> {
    let image = CardImage {
        hash: attachment.get("hash")?.as_str()?.to_owned(),
        mime_type: attachment.get("mime_type")?.as_str()?.to_owned(),
        byte_count: attachment.get("byte_count")?.as_u64()?,
        width: Some(u32::try_from(attachment.get("width")?.as_u64()?).ok()?),
        height: Some(u32::try_from(attachment.get("height")?.as_u64()?).ok()?),
    };
    let card = Card::Browser {
        surface: CardSurface::Browser,
        step: "x".to_owned(),
        live: true,
        target: None,
        url: None,
        image: Some(image.clone()),
    };
    cmux_conversation::valid_card(&card).then_some(image)
}

impl Brain {
    /// The run steps of turn `turn` (with their uploaded pictures named)
    /// move its browser card. Called by `turn_run` after the uploads.
    pub(super) fn browser_steps(
        &mut self,
        conversation: &str,
        turn: &str,
        steps: &mut [Value],
        thread: Option<(String, String)>,
    ) {
        let mut changed = false;
        for step in steps.iter_mut() {
            let browsing = browser_step(step);
            if self.browser_cards_refused
                || self.state.browser_card.as_ref().is_some_and(|c| c.refused)
                || (browsing.is_none()
                    && self.state.browser_card.as_ref().is_none_or(|c| c.turn != turn))
            {
                continue;
            }
            if let Some(browsing) = &browsing {
                if self.state.browser_card.as_ref().is_none_or(|c| c.turn != turn) {
                    // A card an earlier turn left live (a restart, a cut turn) ends first.
                    self.end_browser_card();
                    self.retire_browser_card();
                    self.state.browser_card = Some(BrowserCard {
                        turn: turn.to_owned(),
                        conversation: conversation.to_owned(),
                        key: format!("{turn}:browser"),
                        message_id: None,
                        unsent: false,
                        edits: 0,
                        refused: false,
                        card: Card::Browser {
                            surface: browsing.surface,
                            step: browsing.step.clone(),
                            live: true,
                            target: None,
                            url: None,
                            image: None,
                        },
                        thread: thread.clone(),
                    });
                }
                if let Some(path) = &browsing.screenshot
                    && let Some(attachment) = self.upload_screenshot(conversation, path)
                {
                    let list = step["attachments"].as_array().cloned().unwrap_or_default();
                    if !list.contains(&attachment) {
                        let mut list = list;
                        list.push(attachment);
                        step["attachments"] = json!(list);
                    }
                }
            }
            let image = step
                .get("attachments")
                .and_then(Value::as_array)
                .and_then(|list| list.iter().rev().find_map(card_image));
            let Some(Card::Browser {
                surface,
                step: line,
                target,
                url,
                image: shown,
                live,
            }) = self.state.browser_card.as_mut().map(|c| &mut c.card)
            else {
                continue;
            };
            if let Some(browsing) = browsing {
                // A step of a turn the card had ended for (a cut turn that runs again).
                if !*live {
                    *live = true;
                    changed = true;
                }
                let next_target = browsing.target.or_else(|| target.clone());
                let next_url = browsing.url.or_else(|| url.clone());
                if *surface != browsing.surface
                    || *line != browsing.step
                    || *target != next_target
                    || *url != next_url
                {
                    *surface = browsing.surface;
                    *line = browsing.step;
                    *target = next_target;
                    *url = next_url;
                    changed = true;
                }
            }
            if image.is_some() && *shown != image {
                *shown = image;
                changed = true;
            }
        }
        if changed {
            self.show_browser_card();
        }
    }

    /// A turn ended (or was cut): the browser card stops being live. Any
    /// card, not only this turn's: one turn runs at a time, so a live card
    /// of another turn was left by a restart.
    pub(super) fn browser_turn_ended(&mut self, _turn: &str) {
        self.end_browser_card();
    }

    fn end_browser_card(&mut self) {
        let Some(card) = self.state.browser_card.as_mut() else {
            return;
        };
        match &mut card.card {
            Card::Browser { live, .. } if *live => *live = false,
            _ => return,
        }
        self.show_browser_card();
    }

    /// The owner took a message under `key`: the card message's id.
    pub(super) fn browser_card_sent(&mut self, key: &str, message_id: &str) {
        if let Some(at) = self.state.browser_cards_ending.iter().position(|c| c.key == key) {
            let mut old = self.state.browser_cards_ending.remove(at);
            old.message_id = Some(message_id.to_owned());
            // Called from inside the outbox loop: queued, sent by that loop.
            self.state.outbox.push(edit_entry(&mut old));
            self.save();
            return;
        }
        let Some(card) = self.state.browser_card.as_mut() else {
            return;
        };
        // The owner refused the card and took its text (outbox.rs): no
        // edits follow, and later turns show no browser card either.
        if key == format!("{}:text", card.key) {
            card.refused = true;
            self.browser_cards_refused = true;
            return;
        }
        if card.key != key {
            return;
        }
        card.message_id = Some(message_id.to_owned());
        if std::mem::take(&mut card.unsent) {
            // Called from inside the outbox loop: queued, sent by that loop.
            queue_card(&mut self.state);
            self.save();
        }
    }

    /// Posts the card, or edits it in: a change replaces a queued one.
    fn show_browser_card(&mut self) {
        queue_card(&mut self.state);
        self.save();
        self.flush_outbox();
    }

    /// A card a newer turn replaced before the owner confirmed its first
    /// post: once it does, its last state (ended) is edited in.
    fn retire_browser_card(&mut self) {
        if let Some(old) = self.state.browser_card.take()
            && old.unsent
            && old.message_id.is_none()
            && !old.refused
        {
            let ending = &mut self.state.browser_cards_ending;
            ending.push(old);
            // A bound: an owner that never confirms must not grow the state.
            if ending.len() > 4 {
                ending.remove(0);
            }
        }
    }

    /// The screenshot file at `path` as a run picture of `conversation`.
    fn upload_screenshot(&mut self, conversation: &str, path: &str) -> Option<Value> {
        let home = std::env::var_os("HOME").map(std::path::PathBuf::from);
        let path = super::media::local_path(path, home.as_deref())?;
        let meta = std::fs::metadata(&path).ok()?;
        if !meta.is_file() || meta.len() == 0 || meta.len() > MAX_SCREENSHOT_BYTES {
            return None;
        }
        let bytes = std::fs::read(&path).ok()?;
        let mime_type = match image::guess_format(&bytes).ok()? {
            image::ImageFormat::Png => "image/png",
            image::ImageFormat::Jpeg => "image/jpeg",
            image::ImageFormat::WebP => "image/webp",
            _ => return None,
        };
        use base64::Engine;
        let picture = crate::run::RunImage {
            step: "browser:screenshot".to_owned(),
            mime_type: mime_type.to_owned(),
            data: base64::engine::general_purpose::STANDARD.encode(&bytes),
        };
        let daemon = self.daemon.as_mut()?;
        match super::drafts::upload_image(daemon.as_mut(), conversation, &picture) {
            Ok(attachment) => Some(attachment),
            Err(e) => {
                (self.log)(&format!("uploading a browser screenshot failed: {e}"));
                None
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bash(command: &str, description: Option<&str>, status: &str) -> Value {
        let mut input = json!({"command": command});
        if let Some(d) = description {
            input["description"] = json!(d);
        }
        json!({"id": "tool:1", "kind": "tool", "status": status,
               "tool": {"name": "Bash", "input": input}})
    }

    #[test]
    fn a_cmux_browser_call_is_a_browser_step_on_the_right_column() {
        let step = browser_step(&bash(
            "cmux browser right open --agent Chief https://www.linkedin.com/messaging/",
            Some("Returning to LinkedIn Messaging"),
            "running",
        ))
        .unwrap();
        assert_eq!(step.surface, CardSurface::Browser);
        assert_eq!(step.target.as_deref(), Some("browser:right"));
        assert_eq!(step.step, "Returning to LinkedIn Messaging");
        assert_eq!(step.url.as_deref(), Some("https://www.linkedin.com/messaging/"));
    }

    #[test]
    fn an_undescribed_call_reads_as_its_verb() {
        let step = browser_step(&bash(
            "cmux browser right open https://www.linkedin.com/login",
            None,
            "running",
        ))
        .unwrap();
        assert_eq!(step.step, "Opening www.linkedin.com");
        let click = browser_step(&bash("cmux browser right click '#send'", None, "running"));
        assert_eq!(click.unwrap().step, "Clicking on the page");
    }

    #[test]
    fn a_done_screenshot_names_its_file() {
        let running = bash("cmux browser right screenshot --out /tmp/s.png", None, "running");
        assert_eq!(browser_step(&running).unwrap().screenshot, None);
        let done = bash("cmux browser right screenshot --out=/tmp/s.png", None, "done");
        assert_eq!(browser_step(&done).unwrap().screenshot.as_deref(), Some("/tmp/s.png"));
    }

    #[test]
    fn a_cloud_cua_call_is_a_computer_step_on_its_machine() {
        let step = browser_step(&bash(
            "cmux cloud exec --target machine:m_42 -- ~/.cache/chief/cua.sh click 10 20",
            Some("Opening Settings on the machine"),
            "running",
        ))
        .unwrap();
        assert_eq!(step.surface, CardSurface::Computer);
        assert_eq!(step.target.as_deref(), Some("machine:m_42"));
        assert_eq!(step.step, "Opening Settings on the machine");
    }

    #[test]
    fn mcp_tools_by_name_and_other_calls_are_not_browsing() {
        let computer = json!({"tool": {"name": "mcp__computer-use__screenshot"}});
        assert_eq!(browser_step(&computer).unwrap().surface, CardSurface::Computer);
        assert!(browser_step(&bash("git status", None, "done")).is_none());
        assert!(browser_step(&json!({"kind": "talk", "text": "hi"})).is_none());
    }

    #[test]
    fn only_a_valid_picture_is_a_screenshot() {
        let good = json!({"hash": "a".repeat(64), "mime_type": "image/png", "byte_count": 10,
                          "width": 100, "height": 50, "name": "x.png"});
        assert_eq!(card_image(&good).unwrap().width, Some(100));
        let gif = json!({"hash": "a".repeat(64), "mime_type": "image/gif", "byte_count": 10,
                         "width": 100, "height": 50});
        assert!(card_image(&gif).is_none());
    }
}
