//! The chat's unsent draft in the terminal chat: the same durable draft the app's chat keeps
//! (`_acpmux/draft_get`, `_acpmux/draft_set`, `meta.composer_draft` in the session's
//! `session.json`), so text typed here survives a crash of the TUI, a restart of it or of the
//! daemon, and a switch to another chat, and the app's chat pane shows it too.
//!
//! Leo, 2026-11-24: "big disaster in Mango! i had a draft too that i wanted to send :(".
//!
//! The TUI has one composer (`App::input`) shared by its chats. It is bound to one chat at a time
//! (`DraftSync::bound`): selecting another chat writes the composer's text to the chat it leaves,
//! then fills it with the new chat's draft once acpmux answers the read. Edits are written
//! coalesced: a pause of [`QUIET`] or at most [`BOUND`] after the first unsaved keystroke, so no
//! typed text waits in memory longer than that. A quit, a focus loss and a chat switch write at
//! once. Writes go one at a time, in order, so an older write can never land over a newer one or
//! a clear. A send empties the composer and that empty text is written like any edit (the daemon
//! already clears a draft its prompt sent, `hub/drafts.rs` `clear_sent_draft`).
//!
//! When the read answers, the merge rule is the app chat's (`webviews/src/agent-session/acpmux/
//! composerDraft.ts`, `hydratedDraft` and `mergedDraft`, ported below): text the person typed
//! before this chat's first read is kept beside acpmux's draft, never in place of it; once read,
//! an untouched composer takes acpmux's draft (another pane may have written a newer one), and a
//! touched one is the draft.

use super::*;
use std::time::Duration;

/// A pause in typing this long writes the draft.
pub(super) const QUIET: Duration = Duration::from_millis(250);
/// No typed text waits longer than this after its first unsaved keystroke.
pub(super) const BOUND: Duration = Duration::from_secs(1);
/// A failed write is tried again after this long (a daemon restart, a dropped peer).
const RETRY: Duration = Duration::from_secs(2);
/// How long a quit waits for the last draft to land.
pub(super) const SETTLE: Duration = Duration::from_secs(3);

/// What goes between a saved draft and text typed after it (`mergedDraft`).
const DRAFT_SEPARATOR: &str = "\n\n";

/// `mergedDraft`: the prompt once a saved draft meets text the composer already holds, typed
/// before this chat's draft was read. Nothing is lost and nothing is doubled: an empty side gives
/// way to the other, two different texts are both kept, the saved one first. Dedupe is exact only.
pub(crate) fn merged_draft(typed: &str, saved: Option<&str>) -> String {
    let Some(saved) = saved.filter(|s| !s.trim().is_empty()) else { return typed.to_owned() };
    if typed.trim().is_empty() {
        return saved.to_owned();
    }
    if typed == saved
        || typed.strip_prefix(saved).is_some_and(|rest| rest.starts_with(DRAFT_SEPARATOR))
    {
        return typed.to_owned();
    }
    if saved.strip_suffix(typed).is_some_and(|head| head.ends_with(DRAFT_SEPARATOR)) {
        return saved.to_owned();
    }
    format!("{saved}{DRAFT_SEPARATOR}{typed}")
}

/// What the composer does when the draft read answers (`hydratedDraft`).
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Hydrated {
    /// The prompt to show.
    pub text: String,
    /// Whether it differs from the editor.
    pub shown: bool,
    /// Whether it goes to acpmux.
    pub write: bool,
}

/// What `hydrated_draft` knows of a chat besides the texts.
#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct History {
    /// This TUI read the chat's draft before.
    pub read: bool,
    /// The person edited the prompt since the last settled read.
    pub edited: bool,
    /// The person sent from the prompt since the last settled read.
    pub sent: bool,
    /// A write of this TUI's is queued or unanswered.
    pub pending_write: bool,
}

/// `hydratedDraft`, the one rule: a touched prompt is the draft and acpmux's is never merged into
/// it, except text typed before the chat's first read, which is kept beside acpmux's draft.
/// Untouched with nothing on its way, acpmux's draft fills the prompt.
pub(crate) fn hydrated_draft(current: &str, restored: Option<&str>, h: History) -> Hydrated {
    let restored_text = restored.unwrap_or("");
    let keep = || Hydrated {
        text: current.to_owned(),
        shown: false,
        write: !h.pending_write && current != restored_text,
    };
    let merge = || {
        let text = merged_draft(current, restored);
        Hydrated {
            shown: text != current,
            write: text != restored_text && !text.trim().is_empty(),
            text,
        }
    };
    if h.edited || h.sent || h.pending_write {
        if h.sent || h.pending_write || h.read || restored.is_none_or(str::is_empty) {
            return keep();
        }
        return merge();
    }
    if h.read {
        return Hydrated {
            text: restored_text.to_owned(),
            shown: restored_text != current,
            write: false,
        };
    }
    if restored.is_some_and(|r| !r.is_empty()) { merge() } else { keep() }
}

/// The composer's tie to acpmux's durable drafts.
pub struct DraftSync {
    /// The owner of the draft reads and writes this TUI starts.
    scope: cmux_scope::Scope,
    /// The chat the shared composer holds the draft of.
    pub(super) bound: Option<String>,
    /// The composer's text when last looked at, to see an edit.
    seen: Vec<char>,
    /// The bound chat's history since the composer was bound to it (`History`).
    edited: bool,
    sent: bool,
    /// Whether a read of the bound chat is out.
    reading: bool,
    /// When the first unsaved edit and the last edit came.
    dirty_since: Option<Instant>,
    last_edit: Option<Instant>,
    /// Chats this TUI read the draft of.
    read: HashSet<String>,
    /// What acpmux holds, as far as this TUI knows: the last read or answered write, per chat.
    held: HashMap<String, String>,
    /// The composer's text for a chat it left, shown at once when it comes back.
    left: HashMap<String, String>,
    /// The newest text to write, per chat, and the write on its way.
    pending: HashMap<String, String>,
    in_flight: Option<(String, String)>,
    retry_at: Option<Instant>,
}

impl Default for DraftSync {
    fn default() -> Self {
        Self {
            scope: cmux_scope::Scope::new("tui composer draft"),
            bound: None,
            seen: Vec::new(),
            edited: false,
            sent: false,
            reading: false,
            dirty_since: None,
            last_edit: None,
            read: HashSet::new(),
            held: HashMap::new(),
            left: HashMap::new(),
            pending: HashMap::new(),
            in_flight: None,
            retry_at: None,
        }
    }
}

impl DraftSync {
    fn pending_write(&self, id: &str) -> bool {
        self.pending.contains_key(id) || self.in_flight.as_ref().is_some_and(|(i, _)| i == id)
    }

    /// Whether a draft is still to be written (a quit waits for it).
    pub(super) fn unsettled(&self) -> bool {
        !self.pending.is_empty() || self.in_flight.is_some() || self.dirty_since.is_some()
    }

    /// A write or read failed and waits for its retry: a quit stops waiting for it.
    pub(super) fn failing(&self) -> bool {
        self.retry_at.is_some()
    }

    /// Whether this TUI read `id`'s draft (tests).
    #[cfg(test)]
    pub(super) fn was_read(&self, id: &str) -> bool {
        self.read.contains(id) && !self.reading
    }

    /// The text this TUI wrote or read last for `id` (tests).
    #[cfg(test)]
    pub(super) fn held(&self, id: &str) -> Option<&str> {
        self.held.get(id).map(String::as_str)
    }
}

impl App {
    /// The chat whose draft the shared composer holds now: none on a new-session row, which has
    /// its own editor.
    fn draft_target(&self) -> Option<String> {
        if self.on_draft() { None } else { self.selected_id() }
    }

    /// Run after every input event and tick: follow a chat switch, see an edit, write a draft whose
    /// pause or bound came, retry a failed write.
    pub(super) fn draft_tick(&mut self, now: Instant) {
        if let Some(target) = self.draft_target()
            && self.draft_sync.bound.as_deref() != Some(target.as_str())
        {
            self.bind_draft(target, now);
        }
        self.note_draft_edit(now);
        let s = &self.draft_sync;
        let due = s.dirty_since.is_some_and(|at| now.duration_since(at) >= BOUND)
            || s.last_edit.is_some_and(|at| now.duration_since(at) >= QUIET);
        if due {
            self.queue_bound_draft();
        }
        if self.draft_sync.retry_at.is_some_and(|at| now >= at) {
            self.draft_sync.retry_at = None;
        }
        self.send_next_draft();
    }

    /// Write the composer's draft now: a quit, a focus loss, a chat switch.
    pub(super) fn flush_draft(&mut self) {
        self.note_draft_edit(Instant::now());
        self.queue_bound_draft();
        self.draft_sync.retry_at = None;
        self.send_next_draft();
    }

    /// Read the bound chat's draft again (a reconnect: another pane may have written meanwhile).
    pub(super) fn reread_draft(&mut self) {
        if let Some(id) = self.draft_sync.bound.clone() {
            self.draft_sync.retry_at = None;
            self.read_draft(&id);
        }
    }

    fn note_draft_edit(&mut self, now: Instant) {
        if self.draft_sync.bound.is_none() || self.input.chars() == self.draft_sync.seen.as_slice()
        {
            return;
        }
        self.draft_sync.seen = self.input.chars().to_vec();
        self.draft_sync.edited = true;
        self.draft_sync.dirty_since.get_or_insert(now);
        self.draft_sync.last_edit = Some(now);
    }

    /// The person sent from the composer: what it held is no longer the draft.
    pub(super) fn note_draft_sent(&mut self) {
        if self.draft_sync.bound.is_some() {
            self.draft_sync.sent = true;
        }
    }

    /// Queue the composer's text for the bound chat when acpmux holds something else.
    fn queue_bound_draft(&mut self) {
        let Some(id) = self.draft_sync.bound.clone() else {
            self.draft_sync.dirty_since = None;
            self.draft_sync.last_edit = None;
            return;
        };
        // Unread is never "no draft": text typed before the read waits for it, whose answer keeps
        // both texts and writes them (`on_draft_read`). The edit stays due until then.
        if !self.draft_sync.read.contains(&id) {
            if !self.draft_sync.reading && self.draft_sync.retry_at.is_none() {
                self.read_draft(&id);
            }
            return;
        }
        let s = &mut self.draft_sync;
        s.dirty_since = None;
        s.last_edit = None;
        let text = self.input.text();
        let newest = s
            .pending
            .get(&id)
            .or(s.in_flight.as_ref().filter(|(i, _)| *i == id).map(|(_, t)| t))
            .or(s.held.get(&id));
        // acpmux already holds it, or will once a write on its way lands.
        if newest.map(String::as_str).unwrap_or("") == text {
            return;
        }
        s.pending.insert(id, text);
    }

    /// Bind the composer to `id`: the chat it leaves gets its text, and `id`'s draft is read.
    fn bind_draft(&mut self, id: String, now: Instant) {
        self.note_draft_edit(now);
        if let Some(old) = self.draft_sync.bound.clone() {
            self.queue_bound_draft();
            let text = self.input.text();
            if text.is_empty() {
                self.draft_sync.left.remove(&old);
            } else {
                self.draft_sync.left.insert(old, text);
            }
        }
        // What this TUI last had for `id` shows at once; the read decides what stays.
        let shown = self.draft_sync.left.remove(&id).unwrap_or_default();
        if self.input.text() != shown {
            self.input.set_text(&shown);
        }
        let s = &mut self.draft_sync;
        s.seen = self.input.chars().to_vec();
        s.edited = false;
        s.sent = false;
        s.dirty_since = None;
        s.last_edit = None;
        s.bound = Some(id.clone());
        self.read_draft(&id);
    }

    fn read_draft(&mut self, id: &str) {
        self.draft_sync.reading = true;
        let client = self.client.clone();
        let tx = self.tx.clone();
        let id = id.to_owned();
        self.draft_sync.scope.spawn_named("draft read", async move {
            let read = client.request(method::MUX_DRAFT_GET, json!({"sessionId": id})).await;
            let draft = read.map(|v| v.get("draft").and_then(Value::as_str).map(str::to_owned));
            let _ = tx.send(AppMsg::DraftRead { id, draft: draft.map_err(|e| e.to_string()) });
        });
    }

    pub(super) fn on_draft_read(&mut self, id: String, draft: Result<Option<String>, String>) {
        let Ok(draft) = draft else {
            // Unread is never "no draft": the composer keeps what it holds, and a later edit or
            // reconnect writes or reads again.
            if self.draft_sync.bound.as_deref() == Some(id.as_str()) {
                self.draft_sync.reading = false;
                self.draft_sync.retry_at = Some(Instant::now() + RETRY);
            }
            return;
        };
        let pending = self.draft_sync.pending_write(&id);
        if self.draft_sync.bound.as_deref() != Some(id.as_str()) {
            // A read for a chat the composer already left. Text typed there before this first read
            // was kept aside (`bind_draft`): it joins acpmux's draft now, as it would have there.
            let was_read = self.draft_sync.read.contains(&id);
            if !pending {
                self.note_held(&id, draft.as_deref());
            }
            self.draft_sync.read.insert(id.clone());
            if let Some(typed) = self.draft_sync.left.get(&id).cloned().filter(|_| !was_read) {
                let h = History { read: false, edited: true, sent: false, pending_write: pending };
                let out = hydrated_draft(&typed, draft.as_deref(), h);
                if out.write {
                    self.draft_sync.pending.insert(id.clone(), out.text.clone());
                }
                self.draft_sync.left.insert(id, out.text);
                self.send_next_draft();
            }
            return;
        }
        self.note_draft_edit(Instant::now());
        let current = self.input.text();
        let s = &self.draft_sync;
        let h = History {
            read: s.read.contains(&id),
            edited: s.edited,
            sent: s.sent,
            pending_write: pending,
        };
        let out = hydrated_draft(&current, draft.as_deref(), h);
        let s = &mut self.draft_sync;
        s.reading = false;
        s.read.insert(id.clone());
        if !pending {
            s.edited = false;
            s.sent = false;
            match draft.as_deref() {
                Some(d) if !d.is_empty() => s.held.insert(id.clone(), d.to_owned()),
                _ => s.held.remove(&id),
            };
        }
        if out.shown {
            self.input.set_text(&out.text);
            self.draft_sync.seen = self.input.chars().to_vec();
        }
        if out.write {
            self.draft_sync.pending.insert(id, out.text);
            self.send_next_draft();
        }
    }

    fn note_held(&mut self, id: &str, draft: Option<&str>) {
        match draft {
            Some(d) if !d.is_empty() => self.draft_sync.held.insert(id.to_owned(), d.to_owned()),
            _ => self.draft_sync.held.remove(id),
        };
    }

    /// Send the next queued write, one at a time so they land in order.
    fn send_next_draft(&mut self) {
        let s = &mut self.draft_sync;
        if s.in_flight.is_some() || s.retry_at.is_some() {
            return;
        }
        let Some(id) = s.pending.keys().next().cloned() else { return };
        let text = s.pending.remove(&id).unwrap_or_default();
        s.in_flight = Some((id.clone(), text.clone()));
        let client = self.client.clone();
        let tx = self.tx.clone();
        self.draft_sync.scope.spawn_named("draft write", async move {
            let res = client
                .request(method::MUX_DRAFT_SET, json!({"sessionId": id, "text": text}))
                .await
                .map(|_| ())
                .map_err(|e| e.to_string());
            let _ = tx.send(AppMsg::DraftWritten { id, text, result: res });
        });
    }

    pub(super) fn on_draft_written(
        &mut self,
        id: String,
        text: String,
        result: Result<(), String>,
    ) {
        let s = &mut self.draft_sync;
        if s.in_flight.as_ref().is_some_and(|(i, t)| *i == id && *t == text) {
            s.in_flight = None;
        }
        match result {
            Ok(()) => {
                // acpmux keeps a whitespace-only draft as none.
                let held = if text.trim().is_empty() { None } else { Some(text.as_str()) };
                self.note_held(&id, held);
            }
            Err(e) => {
                // Kept for the next try, unless a newer text is queued; a chat that is gone has
                // nowhere to keep it.
                let listed = self
                    .sessions
                    .iter()
                    .any(|r| session_route_id(r).as_deref() == Some(id.as_str()));
                if listed {
                    self.draft_sync.pending.entry(id).or_insert(text);
                    self.draft_sync.retry_at = Some(Instant::now() + RETRY);
                }
                self.status = format!("draft not saved yet: {e}");
            }
        }
        self.send_next_draft();
    }
}
