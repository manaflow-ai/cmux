//! The device-wide chat index in the daemon (ALL-CHATS-ON-DEVICE C1-C5).
//!
//! `cmux-chat-index` holds the adapters, root discovery and the merged
//! index as pure code. This module wires them to the daemon: the login
//! environment, the guarded-folder refusal, the recorded roots file, one
//! file-system watcher over the root real paths (FSEvents on macOS, no
//! polling), and the change feed that `_acpmux/chats_watch` forwards.
//!
//! Titles and folders are user data: the cache file is 0600 and nothing
//! here logs them. Transcripts are read by the adapters only for metadata.

use cmux_json::JsonSet as _;

mod activity;
pub(crate) mod brand;
mod open;
mod query;
mod resolve;
pub mod search;
mod settings;
pub(crate) mod sources;
pub mod text;
mod watch;
mod window;

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};

use cmux_chat_index::{
    AdapterKind, ChatChange, ChatIndex, ChatKey, Discovery, DiscoveryInput, IndexedChat,
    RecordedRoots, RefusedRoot, RootSource, RootSpec, discover,
};
use serde_json::{Value, json};
use tokio::sync::broadcast;

pub use activity::{
    ActivityCache, ChatActivity, activity_change, changes_activity, session_chat_key,
};
pub use brand::brand_for;
pub(crate) use open::store_dirs;
pub use open::{StoreProfile, plan_open, store_profiles};
pub use query::{ChatCursor, ChatQuery};
pub use resolve::Resolved;
pub use settings::{ChatSettings, SettingsRefusal, probe};
pub use sources::{ChatSources, EnvLookup, launch_roots, login_var, lookup, refusal};
pub use window::{WindowRows, WindowSpec, WindowState};

/// Work run once the chat index has started.
pub type ChatsWaiter = Box<dyn FnOnce(&Arc<ChatService>) + Send>;

/// One index change and its sequence number: numbered under the index lock
/// in the order the index applied them, so a page's `seq` (the last change it
/// contains) and the changes after it never overlap or leave a gap.
#[derive(Clone, Debug)]
pub struct SeqChange {
    pub seq: u64,
    pub change: ChatChange,
}

/// The index, its roots and the watcher over them.
pub struct ChatService {
    sources: ChatSources,
    state: Mutex<State>,
    changes: broadcast::Sender<Arc<Vec<SeqChange>>>,
    /// Connection ids with a live `_acpmux/chats_watch`, each with the
    /// generation of its forwarding task (a re-enable starts a new one).
    watching: Mutex<(u64, HashMap<String, u64>)>,
    /// What was said in each chat, for a window's search by it (`text.rs`); filled by the thread
    /// [`Self::start`] starts.
    text: text::ChatText,
}

struct State {
    index: ChatIndex,
    refused: Vec<RefusedRoot>,
    recorded: RecordedRoots,
    /// The app's settings (`_acpmux/chat_settings`) and the roots they name that are refused.
    settings: ChatSettings,
    settings_refused: Vec<SettingsRefusal>,
    watcher: Option<watch::RootWatcher>,
    watch_errors: Vec<String>,
    /// The sequence number of the last published change (0: none yet).
    seq: u64,
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

impl ChatService {
    /// Discovers the roots, starts the watcher, then scans every root
    /// (incremental from the cache). Blocking: call it off the executor.
    pub fn start(sources: ChatSources) -> Arc<Self> {
        let recorded = RecordedRoots::load(recorded_roots_path(&sources));
        let settings = ChatSettings::load(&settings_path(&sources));
        let (found, settings_refused) = discover_roots(&sources, recorded.roots(), &settings);
        let index = ChatIndex::load(&cache_path(&sources), found.roots);
        let (changes, _) = broadcast::channel(256);
        let text = text::ChatText::new(text_path(&sources));
        let service = Arc::new(Self {
            sources,
            state: Mutex::new(State {
                index,
                refused: found.refused,
                recorded,
                settings,
                settings_refused,
                watcher: None,
                watch_errors: Vec::new(),
                seq: 0,
            }),
            changes,
            watching: Mutex::new((0, HashMap::new())),
            text,
        });
        // Watch first: a file written during the scan is applied after it.
        service.rewatch();
        let mut state = lock(&service.state);
        state.index.rescan_all();
        service.save(&state.index);
        state.index.take_structural_change();
        drop(state);
        service.start_text();
        service
    }

    /// Starts the thread that keeps [`Self::text`] current: it loads the saved text, reads every
    /// chat whose text is missing or older, then reads again after each index change (a burst
    /// settles for [`TEXT_SETTLE`] first), until the service is dropped and its change channel
    /// closes.
    fn start_text(self: &Arc<Self>) {
        let service = Arc::downgrade(self);
        let mut changes = self.subscribe();
        // task-owner: the chat service; ends when it is dropped (the change channel closes).
        let started =
            std::thread::Builder::new().name("acpmux-chat-text".into()).spawn(move || {
                if let Some(service) = service.upgrade() {
                    service.text.load();
                }
                loop {
                    let Some(live) = service.upgrade() else { return };
                    live.index_text();
                    drop(live);
                    match changes.blocking_recv() {
                        Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => {}
                        Err(broadcast::error::RecvError::Closed) => return,
                    }
                    std::thread::sleep(TEXT_SETTLE);
                    while matches!(
                        changes.try_recv(),
                        Ok(_) | Err(broadcast::error::TryRecvError::Lagged(_))
                    ) {}
                }
            });
        if let Err(error) = started {
            tracing::warn!(%error, "chat text: thread not started");
        }
    }

    /// One pass of the text thread: every chat the person sees (none while chats are off).
    fn index_text(&self) {
        let every = ChatQuery { limit: usize::MAX, ..ChatQuery::default() };
        let chats = self.listed_from(&every).unwrap_or_default();
        self.text.update(&chats, &|entry| transcript_turns(entry).ok());
    }

    /// What was said in each chat (`text.rs`).
    pub fn text(&self) -> &text::ChatText {
        &self.text
    }

    pub fn subscribe(&self) -> broadcast::Receiver<Arc<Vec<SeqChange>>> {
        self.changes.subscribe()
    }

    /// One page of chats, newest first, and the cursor of the next page.
    pub fn list(&self, query: &ChatQuery) -> (Vec<Value>, Option<String>) {
        let (page, next, _) = self.list_at(query);
        (page, next)
    }

    /// `list` and the sequence number of the last change the page contains
    /// (read under the same lock): a watcher applies only changes after it.
    pub fn list_at(&self, query: &ChatQuery) -> (Vec<Value>, Option<String>, u64) {
        let state = lock(&self.state);
        let seq = state.seq;
        if !state.settings.enabled {
            return (Vec::new(), None, seq);
        }
        let matching: Vec<&IndexedChat> =
            state.index.newest_first().filter(|chat| query.matches(chat)).collect();
        let start = query.cursor.start(&matching);
        let held = matching.get(start..).unwrap_or_default();
        let held = &held[..held.len().min(query.limit)];
        let page: Vec<Value> = held.iter().map(|c| chat_value(c)).collect();
        let more = start + held.len() < matching.len();
        let next = held.last().filter(|_| more).map(|last| ChatCursor::after(last).to_text());
        (page, next, seq)
    }

    /// Every chat the filter passes from its cursor on, newest first, copied out of the lock so
    /// a caller can read their transcripts (`_acpmux/chats_search`); None while chats are off.
    /// The filter's `limit` is the caller's to apply.
    pub fn listed_from(&self, query: &ChatQuery) -> Option<Vec<IndexedChat>> {
        let state = lock(&self.state);
        if !state.settings.enabled {
            return None;
        }
        let matching: Vec<&IndexedChat> =
            state.index.newest_first().filter(|chat| query.matches(chat)).collect();
        let start = query.cursor.start(&matching);
        Some(matching.get(start..).unwrap_or_default().iter().map(|c| (*c).clone()).collect())
    }

    /// The rows of a client's window (`_acpmux/chats_window`), read under the index lock: none
    /// while chats are off.
    pub fn window_rows(&self, spec: &WindowSpec, activity: &ChatActivity) -> WindowRows {
        let state = lock(&self.state);
        if !state.settings.enabled {
            return WindowRows::default();
        }
        window::rows(spec, &state.index, activity, Some(&self.text))
    }

    /// `_acpmux/chat_projects`: each harness's project folders, every absolute chat folder with
    /// the time of its newest chat (a chat another chat started left out), by harness id then
    /// path. acpmux groups its own index, so the cmux daemon reads a few rows, never every chat.
    /// None while chats are off.
    pub fn projects(&self, activity: &ChatActivity) -> Option<Vec<Value>> {
        let state = lock(&self.state);
        if !state.settings.enabled {
            return None;
        }
        let mut newest: std::collections::BTreeMap<(&str, &str), i64> =
            std::collections::BTreeMap::new();
        for chat in state.index.newest_first() {
            let entry = &chat.entry;
            let Some(cwd) = entry.cwd.as_deref().filter(|cwd| cwd.starts_with('/')) else {
                continue;
            };
            if activity.has_parent(&key_text(&entry.key())) {
                continue;
            }
            let used = newest.entry((entry.harness.id(), cwd)).or_insert(i64::MIN);
            *used = (*used).max(entry.updated_ms);
        }
        Some(
            newest
                .into_iter()
                .map(|((harness, path), used)| json!({"harness": harness, "path": path, "lastUsedMs": used}))
                .collect(),
        )
    }

    pub fn get(&self, key: &ChatKey) -> Option<IndexedChat> {
        lock(&self.state).index.get(key).cloned()
    }

    /// The roots, the refused roots with their reasons, and watcher errors.
    pub fn roots_view(&self) -> Value {
        let state = lock(&self.state);
        let roots: Vec<Value> = state
            .index
            .roots()
            .map(|root| {
                let mut value = serde_json::to_value(root).unwrap_or(Value::Null);
                value.set("id", Value::String(root.id()));
                value
            })
            .collect();
        json!({
            "roots": roots,
            "refused": state.refused,
            "recordedFile": state.recorded.path(),
            "watchErrors": state.watch_errors,
            "settings": state.settings,
            "settingsRefused": state.settings_refused,
        })
    }

    /// Reads the settings file again: settings sent while the index was
    /// starting were only saved. Blocking.
    pub fn reload_settings(self: &Arc<Self>) {
        let saved = ChatSettings::load(&settings_path(&self.sources));
        let changed = {
            let mut state = lock(&self.state);
            let changed = state.settings != saved;
            state.settings = saved;
            changed
        };
        if changed {
            self.refresh_roots();
        }
    }

    /// Whether the person turned chats on (`agents.chats.enabled`).
    pub fn enabled(&self) -> bool {
        lock(&self.state).settings.enabled
    }

    /// Applies and saves the app's settings, then finds the roots again
    /// (a root that leaves takes its chats with it). Blocking.
    pub fn apply_settings(self: &Arc<Self>, settings: ChatSettings) -> Result<(), String> {
        settings
            .save(&settings_path(&self.sources))
            .map_err(|e| format!("save the chat settings: {e}"))?;
        let changed = {
            let mut state = lock(&self.state);
            let changed = state.settings != settings;
            state.settings = settings;
            changed
        };
        if changed {
            self.refresh_roots();
        }
        Ok(())
    }

    /// Records the store root of a transcript a harness reported (a hook's
    /// `transcript_path`), then picks up the root. True when it is new.
    /// Blocking.
    pub fn record_transcript(
        self: &Arc<Self>,
        harness: AdapterKind,
        transcript: &Path,
    ) -> Result<bool, String> {
        let spec = RootSpec::from_transcript(harness, transcript).ok_or_else(|| {
            format!("{} is not a {} transcript path", transcript.display(), harness.id())
        })?;
        if let Some(reason) = self.sources.refusal(&spec.path) {
            return Err(reason);
        }
        let new = lock(&self.state)
            .recorded
            .record(spec)
            .map_err(|e| format!("record the chat root: {e}"))?;
        if new {
            self.refresh_roots();
        }
        Ok(new)
    }

    /// The chat a pasted reference names (`/resume <ref>`, `resolve.rs`): an id, its start, a
    /// transcript path or a resume command. A transcript file outside every root is recorded
    /// (`record_transcript`), then resolved again. Blocking.
    pub fn resolve_ref(self: &Arc<Self>, text: &str) -> Resolved {
        let home = dirs::home_dir().unwrap_or_default();
        let text = resolve::normalize(text, &home);
        let find = || {
            let state = lock(&self.state);
            resolve::resolve(
                &text,
                state.index.chats().into_iter().map(|chat| &chat.entry),
                |path| path.is_file(),
            )
        };
        let found = match find() {
            // A full id the index lacks: its transcript on disk, recorded below.
            Resolved::NotFound => self
                .transcript_on_disk(&text)
                .map_or(Resolved::NotFound, |(_, path)| Resolved::Unindexed(path)),
            other => other,
        };
        match found {
            Resolved::Unindexed(path) => {
                let codex = path.components().any(|part| part.as_os_str() == ".codex")
                    || path
                        .file_name()
                        .and_then(|name| name.to_str())
                        .is_some_and(|name| name.starts_with("rollout-"));
                let harness = if codex { AdapterKind::Codex } else { AdapterKind::ClaudeCode };
                match self.record_transcript(harness, &path) {
                    Ok(_) => match find() {
                        Resolved::Unindexed(_) => Resolved::NotFound,
                        other => other,
                    },
                    Err(_) => Resolved::NotFound,
                }
            }
            other => other,
        }
    }

    /// The transcript of session id `id` under the default and configured Claude Code and Codex
    /// stores (`resolve::find_on_disk`).
    fn transcript_on_disk(&self, id: &str) -> Option<(AdapterKind, PathBuf)> {
        let roots = |kind: AdapterKind| -> Vec<PathBuf> {
            self.sources
                .launch_roots
                .iter()
                .chain(&self.sources.user_roots)
                .filter(|root| root.harness == kind)
                .map(|root| root.path.clone())
                .collect()
        };
        let mut claude = vec![self.sources.home.join(".claude/projects")];
        claude.extend(roots(AdapterKind::ClaudeCode));
        let mut codex = vec![self.sources.home.join(".codex/sessions")];
        codex.extend(roots(AdapterKind::Codex).into_iter().map(|root| root.join("sessions")));
        resolve::find_on_disk(id, &claude, &codex)
    }

    fn recorded_roots_path(&self) -> PathBuf {
        recorded_roots_path(&self.sources)
    }

    /// Records the store roots a spawn's env named (launch roots, C3); new
    /// ones are scanned and watched. Blocking.
    pub fn record_launch_roots(self: &Arc<Self>, specs: &[RootSpec]) {
        let mut new = false;
        {
            let mut state = lock(&self.state);
            for spec in specs.iter().filter(|s| self.sources.refusal(&s.path).is_none()) {
                // Not under a lost home (`config::refuse_lost_home`): it may be another daemon's.
                let recorded = crate::config::refuse_lost_home(&self.recorded_roots_path())
                    .map_err(std::io::Error::other)
                    .and_then(|()| state.recorded.record(spec.clone()));
                match recorded {
                    Ok(fresh) => new |= fresh,
                    Err(e) => tracing::warn!("record a launch root: {e}"),
                }
            }
        }
        if new {
            self.refresh_roots();
        }
    }

    /// Discovers the roots again; new roots are scanned and watched.
    /// Blocking.
    pub fn refresh_roots(self: &Arc<Self>) {
        let (recorded, settings) = {
            let state = lock(&self.state);
            (state.recorded.roots().to_vec(), state.settings.clone())
        };
        let (found, settings_refused) = discover_roots(&self.sources, &recorded, &settings);
        let paths: Vec<PathBuf> = found.roots.iter().map(|root| root.real_path.clone()).collect();
        let (watcher, errors) = watch::start(&paths, Arc::downgrade(self));
        let mut state = lock(&self.state);
        let known: HashSet<String> = state.index.roots().map(|root| root.id()).collect();
        let fresh: Vec<String> =
            found.roots.iter().map(|root| root.id()).filter(|id| !known.contains(id)).collect();
        let mut changes = state.index.set_roots(found.roots);
        for id in fresh {
            changes.extend(state.index.rescan_root(&id));
        }
        state.refused = found.refused;
        state.settings_refused = settings_refused;
        state.watch_errors = errors;
        let old = std::mem::replace(&mut state.watcher, watcher);
        self.save(&state.index);
        state.index.take_structural_change();
        self.publish(&mut state, changes);
        drop(state);
        // Stopping a watcher may wait for its event thread: never under the lock.
        drop(old);
    }

    /// Applies one debounced batch of watcher events. `rescan`: the watcher
    /// lost events (FSEvents `MustScanSubDirs`, inotify overflow), so the
    /// roots that hold `paths` (all roots when there are none) scan again.
    pub(crate) fn paths_changed(&self, paths: &[PathBuf], rescan: bool) {
        let mut state = lock(&self.state);
        let mut changes = Vec::new();
        if rescan {
            let ids: Vec<String> = state
                .index
                .roots()
                .filter(|root| {
                    paths.is_empty()
                        || paths.iter().any(|p| {
                            p.starts_with(&root.real_path) || root.real_path.starts_with(p)
                        })
                })
                .map(|root| root.id())
                .collect();
            for id in ids {
                changes.extend(state.index.rescan_root(&id));
            }
        }
        changes.extend(state.index.paths_changed(paths));
        // The cache keeps read offsets with their counts, so a restart is
        // correct from any saved state; save only when the chat set changed.
        if state.index.take_structural_change() {
            self.save(&state.index);
        }
        self.publish(&mut state, changes);
    }

    /// Marks `conn` watching. Returns the generation of a new forwarding
    /// task, or None when one already runs.
    pub(crate) fn watch_on(&self, conn: &str) -> Option<u64> {
        let mut watching = lock(&self.watching);
        if watching.1.contains_key(conn) {
            return None;
        }
        watching.0 += 1;
        let generation = watching.0;
        watching.1.insert(conn.to_owned(), generation);
        Some(generation)
    }

    pub(crate) fn watch_off(&self, conn: &str) {
        lock(&self.watching).1.remove(conn);
    }

    /// True while `conn` watches chats (any generation).
    pub(crate) fn watches(&self, conn: &str) -> bool {
        lock(&self.watching).1.contains_key(conn)
    }

    /// True while the forwarding task of `generation` is the live one.
    pub(crate) fn is_watching(&self, conn: &str, generation: u64) -> bool {
        lock(&self.watching).1.get(conn) == Some(&generation)
    }

    /// Numbers `changes` and sends them, under the index lock (a broadcast
    /// send never blocks), so a page read under the lock sees exactly the
    /// changes up to its `seq`.
    fn publish(&self, state: &mut State, changes: Vec<ChatChange>) {
        if changes.is_empty() {
            return;
        }
        let numbered = changes
            .into_iter()
            .map(|change| {
                state.seq += 1;
                SeqChange { seq: state.seq, change }
            })
            .collect();
        let _ = self.changes.send(Arc::new(numbered));
    }

    fn save(&self, index: &ChatIndex) {
        let path = cache_path(&self.sources);
        // Not under a lost home (`config::mark_home_lost`): it may be another daemon's now.
        let saved = crate::config::refuse_lost_home(&path)
            .and_then(|()| index.save(&path).map_err(anyhow::Error::from));
        if let Err(e) = saved {
            tracing::warn!("chat index cache: {e}");
        }
    }

    fn rewatch(self: &Arc<Self>) {
        let paths: Vec<PathBuf> =
            lock(&self.state).index.roots().map(|root| root.real_path.clone()).collect();
        let (watcher, errors) = watch::start(&paths, Arc::downgrade(self));
        let mut state = lock(&self.state);
        state.watch_errors = errors;
        let old = std::mem::replace(&mut state.watcher, watcher);
        drop(state);
        drop(old);
    }
}

fn recorded_roots_path(sources: &ChatSources) -> PathBuf {
    sources.acpmux_home.join("chat-roots.json")
}

fn cache_path(sources: &ChatSources) -> PathBuf {
    sources.acpmux_home.join("chat-index/v1.json")
}

fn text_path(sources: &ChatSources) -> PathBuf {
    sources.acpmux_home.join("chat-index/text-v1.json")
}

/// The text thread reads changed chats this long after a change, so a chat being written is read
/// once per burst, not per line.
const TEXT_SETTLE: std::time::Duration = std::time::Duration::from_secs(2);

fn settings_path(sources: &ChatSources) -> PathBuf {
    sources.acpmux_home.join("chat-settings.json")
}

/// A chat's turns: Claude Code and Codex through adopt's reader (`adopt_replay.rs`, the turns an
/// adopted chat replays), every other harness through `cmux_chat_index::transcript`. Both come
/// out with the same caps, and a file that cannot be read is an error, never "no turns".
pub fn transcript_turns(
    entry: &cmux_chat_index::ChatEntry,
) -> Result<Vec<cmux_chat_index::transcript::Turn>, cmux_chat_index::transcript::TranscriptError> {
    use cmux_chat_index::AdapterKind;
    use cmux_chat_index::transcript::{TranscriptError, Turn, capped};
    let family = match entry.harness {
        AdapterKind::ClaudeCode => "claude",
        AdapterKind::Codex => "codex",
        kind => {
            return cmux_chat_index::transcript::read_turns(
                kind,
                &entry.source_path,
                &entry.session_id,
            );
        }
    };
    // adopt's reader answers an unreadable file with no turns.
    std::fs::File::open(&entry.source_path)
        .map_err(|e| TranscriptError::Unreadable(e.to_string()))?;
    let turns = crate::adopt_replay::read(family, &entry.source_path);
    Ok(turns
        .into_iter()
        .map(|t| Turn {
            prompt: capped(t.prompt),
            // No answer yet has no answer time (adopt's reader starts it at the prompt's).
            answer_at: t.answer_at.filter(|_| !t.answer.is_empty()),
            answer: capped(t.answer),
            prompt_at: t.prompt_at,
        })
        .collect())
}

/// The roots to read under `settings`: none when chats are off; only the
/// user's and managed roots when discovery is off (a listed root that is
/// also a default root stays).
fn discover_roots(
    sources: &ChatSources,
    recorded: &[RootSpec],
    settings: &ChatSettings,
) -> (Discovery, Vec<SettingsRefusal>) {
    let refuse = |path: &Path| sources.refusal(path);
    let (listed, settings_refused) = settings.root_specs(&refuse);
    if !settings.enabled {
        return (Discovery::default(), settings_refused);
    }
    let mut launched = sources.launch_roots.clone();
    launched.extend(recorded.iter().cloned());
    let mut user = sources.user_roots.clone();
    user.extend(listed.iter().cloned());
    let mut found = discover(&DiscoveryInput {
        home: &sources.home,
        env: &*sources.env,
        refuse: &refuse,
        recorded: &launched,
        user: &user,
    });
    if !settings.discovery {
        let real =
            |spec: &RootSpec| std::fs::canonicalize(&spec.path).ok().map(|p| (spec.harness, p));
        let wanted: Vec<(AdapterKind, PathBuf)> = user.iter().filter_map(real).collect();
        found.roots.retain(|root| wanted.contains(&(root.harness, root.real_path.clone())));
        for root in &mut found.roots {
            root.source = RootSource::User;
        }
        found.refused.retain(|root| root.source == RootSource::User);
    }
    (found, settings_refused)
}

/// `<harness>:<session id>`, the key clients pass back.
pub fn key_text(key: &ChatKey) -> String {
    format!("{}:{}", key.harness.id(), key.session_id)
}

/// Parses `key_text`.
pub fn parse_key(text: &str) -> Option<ChatKey> {
    let (harness, session_id) = text.split_once(':')?;
    let harness = AdapterKind::from_id(harness)?;
    (!session_id.is_empty()).then(|| ChatKey { harness, session_id: session_id.to_owned() })
}

/// A chat as clients get it: the index entry, its `key`, and its `brand`
/// (the agent mark id from design/agent-icons, or null), so no client maps
/// harness ids to marks per chat.
pub fn chat_value(chat: &IndexedChat) -> Value {
    let mut value = serde_json::to_value(chat).unwrap_or(Value::Null);
    let key = chat.entry.key();
    value.set("brand", json!(brand::harness_brand(key.harness)));
    value.set("key", Value::String(key_text(&key)));
    value
}

/// The `_acpmux/chat_changed` params of one change, with its `seq`.
pub fn change_value(numbered: &SeqChange) -> Value {
    let seq = numbered.seq;
    match &numbered.change {
        ChatChange::Upsert { chat } => json!({
            "kind": "upsert", "seq": seq, "key": key_text(&chat.entry.key()), "chat": chat_value(chat)
        }),
        ChatChange::Removed { key } => json!({"kind": "removed", "seq": seq, "key": key_text(key)}),
    }
}

impl crate::hub::Hub {
    /// Starts the chat index once (later calls do nothing). Waits for the
    /// first scan; `_acpmux/chats` answers `ready: false` until then.
    pub async fn start_chats(self: &Arc<Self>, sources: ChatSources) -> Result<(), String> {
        if self.chats.get().is_some() {
            return Ok(());
        }
        let service = tokio::task::spawn_blocking(move || ChatService::start(sources))
            .await
            .map_err(|e| format!("chat index start: {e}"))?;
        let _ = self.chats.set(service.clone());
        // Taken under the waiters' lock after the set: a later waiter sees the index.
        let waiters = std::mem::take(&mut *lock(&self.chats_waiters));
        for waiter in waiters {
            waiter(&service);
        }
        // Settings sent during the first scan went only to the file.
        tokio::task::spawn_blocking(move || service.reload_settings())
            .await
            .map_err(|e| format!("chat settings: {e}"))?;
        Ok(())
    }

    /// Applies the app's chat settings; before the index runs, saves them
    /// for its start. Blocking.
    pub fn apply_chat_settings(&self, settings: ChatSettings) -> Result<bool, String> {
        if let Some(service) = self.chats.get() {
            return service.apply_settings(settings).map(|()| true);
        }
        settings
            .save(&crate::config::home().join("chat-settings.json"))
            .map_err(|e| format!("save the chat settings: {e}"))?;
        // The index may have started between the check and the save.
        match self.chats.get() {
            Some(service) => {
                service.reload_settings();
                Ok(true)
            }
            None => Ok(false),
        }
    }

    /// Runs `waiter` once the chat index has started: now when it runs.
    pub fn when_chats_ready(&self, waiter: ChatsWaiter) {
        let mut waiters = lock(&self.chats_waiters);
        match self.chats.get() {
            Some(service) => {
                drop(waiters);
                waiter(service);
            }
            None => waiters.push(waiter),
        }
    }

    pub fn chat_index(&self) -> Option<&Arc<ChatService>> {
        self.chats.get()
    }
}

// What one activity change costs a chat window at 100, 1,000 and 3,000 chats (manual).
#[cfg(test)]
#[path = "update_cost_bench.rs"]
mod update_cost_bench;
