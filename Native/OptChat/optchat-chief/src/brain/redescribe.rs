//! The owner's `optchat-chief memory redescribe` (memory_cli.rs): describes
//! again the image an image note line names, typically one whose first
//! description failed (the 2026-11-09 stuck compactor logged 30 screenshots as
//! `no description (... is taken)`).
//!
//! The note names the image by its short hash and file name. The user line
//! that carries the same reference, near the note, was logged with its
//! conversation message key (`<conversation>#<seq>`); the brain reads that
//! message from the conversation owner, takes its attachment part and the
//! image's bytes again, and asks the describer, off the brain thread. The
//! answer rewrites the note through the memory's change book (backup,
//! journal, every summary above the note marked stale and built again), as an
//! inspector edit does, so `/api/memory/changes` lists it and it can be undone.

use cmux_conversation::Part;
use optchat_core::Kind;
use serde_json::{Value, json};

use super::images::{self, ImageRef, TurnImage};

/// How many lines on each side of a note the user line with its image may be.
const SOURCE_WINDOW: u64 = 400;

/// The short hash and the file name an image note line names: `image
/// sha256:<12 hex> "<name>" shows: ...` or `...": no description (...)`.
pub fn note_image(text: &str) -> Option<(&str, &str)> {
    let rest = text.strip_prefix("image sha256:")?;
    let (hash, rest) = rest.split_once(' ')?;
    if hash.len() != 12 || !hash.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    let rest = rest.strip_prefix('"')?;
    let end = rest
        .find("\" shows: ")
        .or_else(|| rest.find("\": no description ("))?;
    Some((hash, &rest[..end]))
}

/// Whether `text` is an image note whose description failed.
pub fn is_failed_description(text: &str) -> bool {
    note_image(text).is_some() && text.contains("\": no description (")
}

/// The key of this redescription in `Brain::describing`.
fn busy_key(note: u64) -> String {
    format!("redescribe/{note}")
}

impl super::Brain {
    /// Starts a new description of the image each of `notes` names. Answers
    /// `{"started": [ids], "refused": [{"id", "why"}]}` without waiting for
    /// the descriptions; each one rewrites its note when it arrives
    /// (`redescribed`).
    pub(super) fn redescribe(&mut self, notes: &[u64]) -> Value {
        let mut started = Vec::new();
        let mut refused = Vec::new();
        for &note in notes {
            match self.redescribe_one(note) {
                Ok(()) => started.push(note),
                Err(why) => {
                    (self.log)(&format!("redescribe message {note}: refused: {why}"));
                    refused.push(json!({"id": note, "why": why}));
                }
            }
        }
        json!({"started": started, "refused": refused})
    }

    fn redescribe_one(&mut self, note: u64) -> Result<(), String> {
        if self.memory_editor.is_none() {
            return Err("this host has no memory change book".into());
        }
        let Some(describer) = self.describer.clone() else {
            return Err("this host has no image describer".into());
        };
        let (kind, text) = self
            .chat
            .message(note)
            .ok_or_else(|| format!("there is no message {note}"))?;
        if kind != Kind::Note {
            return Err(format!(
                "message {note} is a {} line, not a note",
                kind.as_str()
            ));
        }
        let (short, name) =
            note_image(&text).ok_or_else(|| format!("message {note} is not an image note"))?;
        if self.describing.contains(&busy_key(note)) {
            return Err(format!("message {note} is being described already"));
        }
        let source = self.image_source(note, short, name)?;
        let daemon = self
            .daemon
            .as_mut()
            .ok_or("the conversation owner is not connected")?;
        let image =
            images::read_image(daemon.as_mut(), &source).ok_or("the attachment is not an image")?;
        let blocks = images::describe_blocks(&image).ok_or_else(|| {
            format!(
                "the image is not readable{}",
                image
                    .note
                    .as_deref()
                    .map(|n| format!(": {n}"))
                    .unwrap_or_default()
            )
        })?;
        self.describing.insert(busy_key(note));
        let tx = self.tx.clone();
        // The note needs the reference only, never the bytes.
        let image = TurnImage {
            data: None,
            ..image
        };
        let spawned = std::thread::Builder::new()
            .name("optchat-redescribe".into())
            .spawn(move || {
                let description = describer.describe(blocks);
                let _ = tx.send(super::Input::Redescribed {
                    note,
                    image: Box::new(image),
                    description,
                });
            });
        if let Err(e) = spawned {
            self.describing.remove(&busy_key(note));
            return Err(format!("starting the description failed: {e}"));
        }
        (self.log)(&format!(
            "redescribe message {note}: describing {name} again"
        ));
        Ok(())
    }

    /// The attachment the note's image came from: the nearest line that
    /// carries its reference and was logged from a conversation message,
    /// read again from the owner.
    fn image_source(&mut self, note: u64, short: &str, name: &str) -> Result<ImageRef, String> {
        let reference = format!("[image sha256:{short} \"{name}\"");
        let key = (1..=SOURCE_WINDOW)
            .flat_map(|d| [note.checked_sub(d), note.checked_add(d)])
            .flatten()
            .find_map(|i| {
                let (_, text) = self.chat.message(i)?;
                if !text.contains(&reference) {
                    return None;
                }
                self.chat.logged_key(i)
            })
            .ok_or_else(|| format!("no line near message {note} carries {reference}]"))?;
        let (conversation, seq) = key
            .rsplit_once('#')
            .and_then(|(c, s)| s.parse::<u64>().ok().map(|s| (c.to_owned(), s)))
            .ok_or_else(|| format!("the line's key {key:?} is not <conversation>#<seq>"))?;
        let daemon = self
            .daemon
            .as_mut()
            .ok_or("the conversation owner is not connected")?;
        let message = daemon
            .history(&conversation, seq + 1, 1)
            .map_err(|e| format!("reading message {key} from the owner failed: {e}"))?
            .into_iter()
            .find(|m| m.seq == seq)
            .ok_or_else(|| format!("the owner no longer has message {key}"))?;
        let part = message
            .parts
            .into_iter()
            .find(|p| {
                matches!(p, Part::Attachment { hash, name: n, .. } if hash.starts_with(short) && n == name)
            })
            .ok_or_else(|| format!("message {key} no longer holds the image {name}"))?;
        Ok(ImageRef { conversation, part })
    }

    /// A new description of note `note`'s image: the note is rewritten
    /// through the change book (its summaries are built again there); a
    /// failure leaves the note as it was and is logged.
    pub(super) fn redescribed(
        &mut self,
        note: u64,
        image: &TurnImage,
        description: Result<String, String>,
    ) {
        self.describing.remove(&busy_key(note));
        let text = match description {
            Ok(text) if !text.trim().is_empty() => text,
            Ok(_) => {
                (self.log)(&format!(
                    "redescribe message {note}: the description is empty; kept"
                ));
                return;
            }
            Err(e) => {
                (self.log)(&format!(
                    "redescribe message {note}: describing failed again ({e}); kept"
                ));
                return;
            }
        };
        let Some(editor) = &self.memory_editor else {
            return;
        };
        let line = images::description_line(image, Ok(&text));
        match editor.redescribe(note, &line) {
            Ok(change) => (self.log)(&format!(
                "redescribe message {note}: rewritten (change {}), {} summaries to build again",
                change["id"],
                change["stale"].as_array().map_or(0, Vec::len)
            )),
            Err((code, why)) => (self.log)(&format!(
                "redescribe message {note}: rewriting the note failed ({code}): {why}"
            )),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_note_names_its_image_whether_described_or_failed() {
        let ok =
            "image sha256:8ba4b8f749d7 \"Screenshot 2026-11-09 at 3.13.46 PM.png\" shows: a sheet";
        let failed = "image sha256:8ba4b8f749d7 \"Screenshot 2026-11-09 at 3.13.46 PM.png\": no description (starting a compactor session: session/new: session name \"x\" is taken)";
        let name = "Screenshot 2026-11-09 at 3.13.46 PM.png";
        assert_eq!(note_image(ok), Some(("8ba4b8f749d7", name)));
        assert_eq!(note_image(failed), Some(("8ba4b8f749d7", name)));
        assert!(is_failed_description(failed));
        assert!(!is_failed_description(ok));
        assert_eq!(note_image("image sha256:zz \"a\" shows: b"), None);
        assert_eq!(note_image("user: look"), None);
    }
}
