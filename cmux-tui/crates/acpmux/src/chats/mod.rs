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

mod activity;
mod brand;
mod open;
mod query;
mod settings;
pub(crate) mod sources;
mod watch;

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};

use crate::no_panic::JsonExt;
use cmux_chat_index::{
    AdapterKind, ChatChange, ChatIndex, ChatKey, Discovery, DiscoveryInput, IndexedChat,
    RecordedRoots, RefusedRoot, RootSource, RootSpec, discover,
};
use serde_json::{Value, json};
use tokio::sync::broadcast;

pub use activity::{ChatActivity, activity_change, changes_activity};
pub use brand::brand_for;
pub(crate) use open::store_dirs;
pub use open::{StoreProfile, plan_open, store_profiles};
pub use query::{ChatCursor, ChatQuery};
pub use settings::{ChatSettings, SettingsRefusal, probe};
pub use sources::{ChatSources, EnvLookup, launch_roots, login_var, lookup, refusal};

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
        let recorded = RecordedRoots::load(sources.acpmux_home.join("chat-roots.json"));
        let settings = ChatSettings::load(&settings_path(&sources));
        let (found, settings_refused) = discover_roots(&sources, recorded.roots(), &settings);
        let index = ChatIndex::load(&cache_path(&sources), found.roots);
        let (changes, _) = broadcast::channel(256);
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
        });
        // Watch first: a file written during the scan is applied after it.
        service.rewatch();
        let mut state = lock(&service.state);
        state.index.rescan_all();
        service.save(&state.index);
        state.index.take_structural_change();
        drop(state);
        service
    }

    /// What the index keeps, estimated (a memory consumer's bytes): each chat
    /// twice, in its root's scan and in the merged list. Reads lengths only;
    /// `None` while a scan holds the index (`daemon status` never waits on one).
    pub fn approx_bytes(&self) -> Option<u64> {
        use crate::memory::{inline_bytes, string_bytes};
        let state = match self.state.try_lock() {
            Ok(state) => state,
            Err(std::sync::TryLockError::Poisoned(poisoned)) => poisoned.into_inner(),
            Err(std::sync::TryLockError::WouldBlock) => return None,
        };
        let words = |list: &[String]| list.iter().map(|s| string_bytes(s)).sum::<u64>();
        let bytes = state
            .index
            .chats()
            .into_iter()
            .map(|chat| {
                let e = &chat.entry;
                let entry = inline_bytes::<cmux_chat_index::ChatEntry>(1)
                    + string_bytes(&e.session_id)
                    + e.title.as_deref().map_or(0, string_bytes)
                    + e.cwd.as_deref().map_or(0, string_bytes)
                    + e.source_path.as_os_str().len() as u64
                    + e.originator.as_deref().map_or(0, string_bytes);
                2 * entry
                    + inline_bytes::<IndexedChat>(1)
                    + words(&chat.accounts)
                    + words(&chat.roots)
            })
            .sum();
        Some(bytes)
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
            state.index.chats().into_iter().filter(|chat| query.matches(chat)).collect();
        let start = query.cursor.start(&matching);
        let held = matching.get(start..).unwrap_or_default();
        let held = held.get(..query.limit).unwrap_or(held);
        let page: Vec<Value> = held.iter().map(|c| chat_value(c)).collect();
        let more = start + held.len() < matching.len();
        let next = held.last().filter(|_| more).map(|last| ChatCursor::after(last).to_text());
        (page, next, seq)
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

    /// Records the store roots a spawn's env named (launch roots, C3); new
    /// ones are scanned and watched. Blocking.
    pub fn record_launch_roots(self: &Arc<Self>, specs: &[RootSpec]) {
        let mut new = false;
        {
            let mut state = lock(&self.state);
            for spec in specs.iter().filter(|s| self.sources.refusal(&s.path).is_none()) {
                match state.recorded.record(spec.clone()) {
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
        if let Err(e) = index.save(&cache_path(&self.sources)) {
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

fn cache_path(sources: &ChatSources) -> PathBuf {
    sources.acpmux_home.join("chat-index/v1.json")
}

fn settings_path(sources: &ChatSources) -> PathBuf {
    sources.acpmux_home.join("chat-settings.json")
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
        crate::daemon::spawn_blocking(move || service.reload_settings())
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
