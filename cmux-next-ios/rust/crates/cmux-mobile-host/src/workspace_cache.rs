//! Mac-owned snapshots shared by the splices of one daemon socket. All daemon I/O and delta application run on
//! a separate connection; forwarding only clones an already published snapshot.
//! Losing the subscription invalidates every snapshot before reconnecting.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock, Weak};
use std::time::Duration;

use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::time::Instant;

const QUERY_WAIT: Duration = Duration::from_secs(5);
const MAX_SNAPSHOT_BYTES: u64 = 64 * 1024 * 1024;
const TREE: usize = 0;
const PERSONAL: usize = 1;
const LAYOUT: usize = 2;
type Views = [Option<Arc<Value>>; 3];

#[derive(Clone)]
pub(crate) struct WorkspaceCache {
    inner: Arc<CacheWorker>,
}

struct CacheWorker {
    published: Arc<Published>,
    task: tokio::task::JoinHandle<()>,
}

struct Published {
    views: Mutex<Views>,
    changed: tokio::sync::watch::Sender<()>,
}

impl Published {
    fn new() -> Self {
        Self { views: Mutex::new([None, None, None]), changed: tokio::sync::watch::channel(()).0 }
    }
}

impl WorkspaceCache {
    pub(crate) fn start(path: PathBuf) -> Self {
        static WORKERS: OnceLock<Mutex<HashMap<PathBuf, Weak<CacheWorker>>>> = OnceLock::new();
        let mut workers = WORKERS.get_or_init(Default::default).lock().unwrap_or_else(|e| e.into_inner());
        workers.retain(|_, worker| worker.strong_count() != 0);
        if let Some(inner) = workers.get(&path).and_then(Weak::upgrade) {
            return Self { inner };
        }
        let published = Arc::new(Published::new());
        let updates = Arc::clone(&published);
        let socket = path.clone();
        // The task owns only publication state, never CacheWorker: dropping the
        // last splice aborts I/O and reconnect backoff with no self-retaining cycle.
        let task = tokio::spawn(async move {
            loop {
                let _ = session(&socket, &updates).await;
                publish(&updates, &[None, None, None]);
                // Connection recovery only, never a periodic snapshot refresh.
                tokio::time::sleep(Duration::from_secs(1)).await;
            }
        });
        let inner = Arc::new(CacheWorker { published, task });
        workers.insert(path, Arc::downgrade(&inner));
        Self { inner }
    }

    pub(crate) fn tree(&self) -> Option<Arc<Value>> {
        self.get(TREE)
    }
    pub(crate) fn personal(&self) -> Option<Arc<Value>> {
        self.get(PERSONAL)
    }
    pub(crate) fn layout(&self) -> Option<Arc<Value>> {
        self.get(LAYOUT)
    }

    fn get(&self, kind: usize) -> Option<Arc<Value>> {
        // The writer only swaps three Arc handles under this lock. JSON parsing,
        // tree edits and dropping old snapshots all happen outside it.
        self.inner.published.views.lock().ok()?.get(kind)?.clone()
    }

    /// Used only by the side-request worker, never the keystroke forwarding
    /// task. Subscribe before inspecting state so a publication cannot be lost
    /// between the readiness check and awaiting a change. On timeout the caller
    /// checks the snapshots again and fails closed if any required one is absent.
    pub(crate) async fn wait_for(&self, tree: bool, personal: bool, layout: bool) {
        let required = [tree, personal, layout];
        let mut changed = self.inner.published.changed.subscribe();
        let wait = async {
            loop {
                let ready = self.inner.published.views.lock().is_ok_and(|views| {
                    required.iter().zip(views.iter()).all(|(required, view)| !required || view.is_some())
                });
                if ready || changed.changed().await.is_err() {
                    return;
                }
            }
        };
        let _ = tokio::time::timeout(QUERY_WAIT, wait).await;
    }
}

impl Drop for CacheWorker {
    fn drop(&mut self) {
        self.task.abort();
    }
}

fn publish(published: &Published, views: &Views) {
    let old = {
        let Ok(mut current) = published.views.lock() else { return };
        std::mem::replace(&mut *current, views.clone())
    };
    // A potentially large old JSON tree is destroyed without holding the lock.
    drop(old);
    published.changed.send_replace(());
}

#[derive(Default)]
struct Snapshots {
    views: Views,
    /// An event while a snapshot was in flight makes that answer insufficient.
    dirty: [bool; 3],
    pending: [Option<Instant>; 3],
    /// Deltas at/below this snapshot revision are already represented in it.
    tree_floor: Option<u64>,
}

impl Snapshots {
    fn invalidate(&mut self, kind: usize) {
        self.views[kind] = None;
        self.dirty[kind] = true;
    }

    fn event(&mut self, event: &Value) -> Result<(), ()> {
        let name = event.get("event").and_then(Value::as_str).ok_or(())?;
        match name {
            "overflow" => return Err(()), // The daemon ended this subscription.
            "tree-changed" | "layout-changed" | "empty" => self.invalidate(TREE),
            "personal-changed" | "sidebar-layout-changed" => {
                self.invalidate(PERSONAL);
                self.invalidate(LAYOUT);
            }
            name if ["workspace-", "screen-", "pane-", "tab-"].iter().any(|p| name.starts_with(p)) => {
                let replaced = self.views[TREE].as_ref().is_some_and(|tree| {
                    ["registry_id", "generation"].iter().any(|key| {
                        event.get(*key).is_some_and(|incoming| tree["data"].get(*key) != Some(incoming))
                    })
                });
                if replaced {
                    for kind in 0..3 {
                        self.invalidate(kind);
                    }
                    return Ok(());
                }
                if self.views[TREE].is_some()
                    && self.tree_floor.is_some_and(|floor| {
                        event
                            .get("workspace_revision")
                            .and_then(Value::as_u64)
                            .is_some_and(|revision| revision <= floor)
                    })
                {
                    return Ok(());
                }
                let applied = self.views[TREE].clone().is_some_and(|tree| {
                    let mut next = (*tree).clone();
                    if apply_delta(&mut next, event).is_err() {
                        return false;
                    }
                    self.views[TREE] = Some(Arc::new(next));
                    true
                });
                if !applied {
                    self.invalidate(TREE);
                }
            }
            _ => {}
        }
        Ok(())
    }

    fn answer(&mut self, kind: usize, reply: Value) -> Result<(), ()> {
        self.pending[kind] = None;
        // A change arrived after this request was issued. Leave it unavailable
        // and issue one new request, instead of publishing an uncertain answer.
        if self.dirty[kind] {
            return Ok(());
        }
        let data = reply.get(if kind == LAYOUT { "result" } else { "data" });
        let valid = reply.get("ok") != Some(&Value::Bool(false))
            && data.is_some_and(|v| match kind {
                TREE => v.get("workspaces").is_some_and(Value::is_array),
                PERSONAL => {
                    v.get("groups").is_some_and(Value::is_array)
                        && v.get("workspaces").is_some_and(Value::is_array)
                }
                LAYOUT => v.get("sections").is_some_and(Value::is_array),
                _ => false,
            });
        if kind == TREE {
            self.tree_floor = valid.then(|| reply["data"]["workspace_revision"].as_u64()).flatten();
        }
        if !valid {
            self.views[kind] = None;
            // Older daemons may not have sidebar_layout.get. That optional
            // view stays unavailable without disrupting tree/personal reads.
            // Other failed or malformed replies restart this subscription via
            // the worker's bounded reconnect backoff, rather than leaving a
            // missing snapshot stuck until an unrelated event happens.
            return if kind == LAYOUT && unsupported_layout(&reply) { Ok(()) } else { Err(()) };
        }
        self.views[kind] = Some(Arc::new(reply));
        Ok(())
    }
}

fn unsupported_layout(reply: &Value) -> bool {
    let error = &reply["error"];
    if error.get("code").and_then(Value::as_str) == Some("operation.unsupported") {
        return true;
    }
    let message = error.as_str().or_else(|| error.get("message").and_then(Value::as_str));
    message.is_some_and(|message| {
        // Serde's unknown-operation response on daemons predating this v2
        // method is a legacy error string rather than a typed ResourceError.
        message.contains("unknown variant `sidebar_layout.get`")
    })
}

async fn session(path: &std::path::Path, published: &Published) -> Result<(), ()> {
    let stream =
        tokio::time::timeout(QUERY_WAIT, UnixStream::connect(path)).await.map_err(|_| ())?.map_err(|_| ())?;
    let (read, mut write) = stream.into_split();
    let mut reader = BufReader::new(read);
    // Subscribe before snapshots so no change between the snapshot and
    // subscription can go missing. Negotiate page records for surface checks.
    write.write_all(b"{\"cmd\":\"set-client-info\",\"id\":\"cache-hello\",\"name\":\"cmux-mobile-host\",\"kind\":\"cli\",\"capabilities\":[\"conversation-tabs-v1\",\"page-tabs-v1\"]}\n{\"cmd\":\"subscribe\",\"id\":\"cache-subscribe\",\"tree_events\":\"deltas\"}\n").await.map_err(|_| ())?;
    let mut state = Snapshots::default();
    let mut subscribed = false;
    let startup_deadline = Instant::now() + QUERY_WAIT;
    loop {
        if subscribed {
            for kind in 0..3 {
                if state.pending[kind].is_none() && state.dirty[kind] {
                    state.dirty[kind] = false;
                    state.pending[kind] = Some(Instant::now() + QUERY_WAIT);
                    let request = match kind {
                        TREE => json!({"cmd":"list-workspaces", "id":"cache-tree"}),
                        PERSONAL => json!({"cmd":"list-personal", "id":"cache-personal"}),
                        _ => json!({"protocol":"cmux.protocol/2", "type":"request", "id":"cache-layout",
                            "operation":"sidebar_layout.get", "params":{"machine":"current", "session":"current"}}),
                    };
                    write.write_all(format!("{request}\n").as_bytes()).await.map_err(|_| ())?;
                }
            }
        }
        let deadline =
            if subscribed { state.pending.iter().flatten().min().copied() } else { Some(startup_deadline) };
        let mut line = Vec::new();
        // Bound a corrupt local peer without retaining unbounded partial input.
        let mut bounded = (&mut reader).take(MAX_SNAPSHOT_BYTES + 1);
        let count = match deadline {
            Some(deadline) => tokio::time::timeout_at(deadline, bounded.read_until(b'\n', &mut line))
                .await
                .map_err(|_| ())?
                .map_err(|_| ())?,
            None => bounded.read_until(b'\n', &mut line).await.map_err(|_| ())?,
        };
        if count == 0 || count as u64 > MAX_SNAPSHOT_BYTES || line.last() != Some(&b'\n') {
            return Err(());
        }
        let value: Value = serde_json::from_slice(&line).map_err(|_| ())?;
        if value.get("event").is_some() {
            state.event(&value)?;
        } else {
            match value.get("id").and_then(Value::as_str) {
                Some("cache-hello") if value.get("ok") != Some(&Value::Bool(true)) => return Err(()),
                Some("cache-subscribe") => {
                    if value.get("ok") != Some(&Value::Bool(true)) {
                        return Err(());
                    }
                    subscribed = true;
                    state.dirty = [true; 3];
                }
                Some("cache-tree") => state.answer(TREE, value)?,
                Some("cache-personal") => state.answer(PERSONAL, value)?,
                Some("cache-layout") => state.answer(LAYOUT, value)?,
                Some("cache-hello") => {}
                _ => return Err(()),
            }
        }
        publish(published, &state.views);
    }
}

/// Apply an authoritative entity delta. Unknown parents or malformed payloads
/// require a snapshot; never keep a partly applied tree available to policy.
fn apply_delta(tree: &mut Value, event: &Value) -> Result<(), ()> {
    let data = tree.get_mut("data").ok_or(())?;
    // A restarted daemon cannot amend an earlier registry's authorization view.
    for key in ["registry_id", "generation"] {
        if let Some(incoming) = event.get(key)
            && data.get(key) != Some(incoming)
        {
            return Err(());
        }
    }
    if let (Some(current), Some(incoming)) = (
        data.get("workspace_revision").and_then(Value::as_u64),
        event.get("workspace_revision").and_then(Value::as_u64),
    ) {
        // A subscription event already included in the snapshot may arrive late.
        if incoming < current {
            return Ok(());
        }
        if incoming > current.saturating_add(1) {
            return Err(());
        }
    }
    let name = event.get("event").and_then(Value::as_str).ok_or(())?;
    let (level, operation) = name.split_once('-').ok_or(())?;
    let workspace = event.get("workspace").and_then(Value::as_u64).ok_or(())?;
    let workspaces = data.get_mut("workspaces").and_then(Value::as_array_mut).ok_or(())?;
    let (entities, id, key) = match level {
        "workspace" => (workspaces, workspace, "id"),
        "screen" | "pane" | "tab" => {
            let ws = find(workspaces, "id", workspace)?;
            let screens = ws.get_mut("screens").and_then(Value::as_array_mut).ok_or(())?;
            let screen = event.get("screen").and_then(Value::as_u64).ok_or(())?;
            if level == "screen" {
                (screens, screen, "id")
            } else {
                let screen = find(screens, "id", screen)?;
                let panes = screen.get_mut("panes").and_then(Value::as_array_mut).ok_or(())?;
                let pane = event.get("pane").and_then(Value::as_u64).ok_or(())?;
                if level == "pane" {
                    (panes, pane, "id")
                } else {
                    let pane = find(panes, "id", pane)?;
                    let tabs = pane.get_mut("tabs").and_then(Value::as_array_mut).ok_or(())?;
                    (tabs, event.get("surface").and_then(Value::as_u64).ok_or(())?, "surface")
                }
            }
        }
        _ => return Err(()),
    };
    let position = entities.iter().position(|entity| entity.get(key).and_then(Value::as_u64) == Some(id));
    if operation == "closed" {
        if let Some(position) = position {
            entities.remove(position);
        }
    } else {
        if position.is_none() && operation != "added" {
            return Err(());
        }
        if !matches!(operation, "added" | "changed" | "renamed" | "moved") {
            return Err(());
        }
        let entity =
            event.get("entity").filter(|e| e.get(key).and_then(Value::as_u64) == Some(id)).ok_or(())?.clone();
        // Replacements carry complete child collections. Keep their order unless
        // the event explicitly supplies the new position.
        let index = event
            .get("index")
            .and_then(Value::as_u64)
            .map(|n| usize::try_from(n).map_err(|_| ()))
            .transpose()?
            .or(position)
            .unwrap_or(entities.len());
        if let Some(position) = position {
            entities.remove(position);
        }
        if index > entities.len() {
            return Err(());
        }
        entities.insert(index, entity);
    }
    if let Some(revision) = event.get("workspace_revision") {
        data["workspace_revision"] = revision.clone();
    }
    Ok(())
}

fn find<'a>(entities: &'a mut [Value], key: &str, id: u64) -> Result<&'a mut Value, ()> {
    entities.iter_mut().find(|entity| entity.get(key).and_then(Value::as_u64) == Some(id)).ok_or(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn one_worker_per_socket_lives_only_while_handles_exist() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("daemon.sock");
        let first = WorkspaceCache::start(path.clone());
        let second = WorkspaceCache::start(path);
        assert!(Arc::ptr_eq(&first.inner, &second.inner));
        let worker = Arc::downgrade(&first.inner);
        let copy = first.clone();
        drop(first);
        drop(second);
        assert!(worker.upgrade().is_some());
        drop(copy);
        assert!(worker.upgrade().is_none());
    }

    #[tokio::test]
    async fn readiness_wait_wakes_on_publication_and_checks_only_requested_views() {
        let published = Arc::new(Published::new());
        let cache = WorkspaceCache {
            inner: Arc::new(CacheWorker {
                published: Arc::clone(&published),
                task: tokio::spawn(std::future::pending()),
            }),
        };
        let mut waiting = Box::pin(cache.wait_for(true, false, true));
        tokio::select! {
            biased;
            () = &mut waiting => panic!("required snapshot is still unavailable"),
            () = std::future::ready(()) => {}
        }
        publish(&published, &[Some(Arc::new(tree())), None, None]);
        tokio::select! {
            biased;
            () = &mut waiting => panic!("required snapshot is still unavailable"),
            () = std::future::ready(()) => {}
        }
        publish(
            &published,
            &[Some(Arc::new(tree())), None, Some(Arc::new(json!({"result":{"sections":[]}})))],
        );
        tokio::time::timeout(Duration::from_secs(1), waiting).await.unwrap();
        assert!(cache.tree().is_some());
        assert!(cache.personal().is_none());
        assert!(cache.layout().is_some());
        cache.wait_for(false, false, false).await;
    }

    fn tree() -> Value {
        json!({"ok":true,"data":{"registry_id":"r", "generation":1, "workspace_revision":3,
            "workspaces":[{"id":1,"key":"one","screens":[{"id":2,"panes":[{"id":3,"tabs":[
                {"surface":4,"cwd":"/old"}, {"surface":5,"cwd":"/other"}]}]}]}]}})
    }

    #[test]
    fn deltas_replace_add_move_and_remove_entities() {
        let mut tree = tree();
        apply_delta(
            &mut tree,
            &json!({"event":"tab-changed", "workspace":1,"screen":2,"pane":3,"surface":4,
            "entity":{"surface":4,"cwd":"/new"}}),
        )
        .unwrap();
        assert_eq!(tree["data"]["workspaces"][0]["screens"][0]["panes"][0]["tabs"][0]["cwd"], "/new");
        apply_delta(&mut tree, &json!({"event":"tab-closed", "workspace":1,"screen":2,"pane":3,"surface":5}))
            .unwrap();
        apply_delta(
            &mut tree,
            &json!({"event":"pane-added", "workspace":1,"screen":2,"pane":6,
            "index":0,"entity":{"id":6,"tabs":[]}}),
        )
        .unwrap();
        assert_eq!(tree["data"]["workspaces"][0]["screens"][0]["panes"][0]["id"], 6);
        apply_delta(
            &mut tree,
            &json!({"event":"workspace-added", "workspace":7,
            "entity":{"id":7,"key":"two","screens":[]}}),
        )
        .unwrap();
        apply_delta(
            &mut tree,
            &json!({"event":"workspace-moved", "workspace":7,"index":0,
            "entity":{"id":7,"key":"two","screens":[]}}),
        )
        .unwrap();
        assert_eq!(tree["data"]["workspaces"][0]["key"], "two");
        apply_delta(&mut tree, &json!({"event":"workspace-closed", "workspace":1})).unwrap();
        assert_eq!(tree["data"]["workspaces"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn malformed_delta_and_coarse_events_invalidate_snapshots() {
        let mut state = Snapshots {
            views: [Some(Arc::new(tree())), Some(Arc::new(json!({}))), Some(Arc::new(json!({})))],
            ..Default::default()
        };
        state
            .event(&json!({"event":"tab-changed", "workspace":1,"screen":2,"pane":3,"surface":4,
            "entity":{"surface":99}}))
            .unwrap();
        assert!(state.views[TREE].is_none());
        state.event(&json!({"event":"personal-changed"})).unwrap();
        assert!(state.views.iter().all(Option::is_none));
        assert_eq!(state.dirty, [true; 3]);
        state.views[TREE] = Some(Arc::new(tree()));
        state.event(&json!({"event":"tree-changed"})).unwrap();
        assert!(state.views[TREE].is_none());
        assert!(state.event(&json!({"event":"overflow"})).is_err());
    }

    #[test]
    fn in_flight_invalidation_does_not_publish_an_old_answer() {
        let mut state = Snapshots::default();
        state.pending[TREE] = Some(Instant::now() + QUERY_WAIT);
        state.event(&json!({"event":"workspace-closed", "workspace":1})).unwrap();
        state.answer(TREE, tree()).unwrap();
        assert!(state.views[TREE].is_none());
        assert!(state.dirty[TREE]);
        // The worker clears dirty when it issues the replacement snapshot.
        state.dirty[TREE] = false;
        state.answer(TREE, tree()).unwrap();
        assert!(state.views[TREE].is_some());
    }

    #[test]
    fn screen_replacement_keeps_new_children_and_revision_gaps_invalidate() {
        let mut state = Snapshots::default();
        state.views[TREE] = Some(Arc::new(tree()));
        state
            .event(&json!({"event":"screen-changed", "workspace":1,"screen":2,
            "workspace_revision":4,"entity":{"id":2,"panes":[{"id":8,"tabs":[]}]}}))
            .unwrap();
        let snapshot = state.views[TREE].as_ref().unwrap();
        assert_eq!(snapshot["data"]["workspaces"][0]["screens"][0]["panes"][0]["id"], 8);
        state.event(&json!({"event":"workspace-closed", "workspace":1,"workspace_revision":6})).unwrap();
        assert!(state.views[TREE].is_none());
    }

    #[test]
    fn old_delta_cannot_restore_data_from_before_the_snapshot() {
        let mut original = tree();
        original["data"]["workspace_revision"] = json!(10);
        let mut updated = original.clone();
        apply_delta(
            &mut updated,
            &json!({"event":"workspace-changed", "workspace":1,
            "workspace_revision":9,"entity":{"id":1,"key":"old","screens":[]}}),
        )
        .unwrap();
        assert_eq!(updated, original);
    }

    #[test]
    fn snapshot_revision_is_a_floor_but_new_transaction_deltas_all_apply() {
        let mut state = Snapshots::default();
        state.answer(TREE, tree()).unwrap();
        state.event(&json!({"event":"workspace-closed", "workspace":1,"workspace_revision":3})).unwrap();
        assert_eq!(state.views[TREE].as_ref().unwrap()["data"]["workspaces"].as_array().unwrap().len(), 1);
        for surface in [4, 5] {
            state
                .event(&json!({"event":"tab-changed", "workspace":1,"screen":2,"pane":3,"surface":surface,
                "workspace_revision":4,"entity":{"surface":surface,"cwd":"/new"}}))
                .unwrap();
        }
        let tabs =
            &state.views[TREE].as_ref().unwrap()["data"]["workspaces"][0]["screens"][0]["panes"][0]["tabs"];
        assert!(tabs.as_array().unwrap().iter().all(|tab| tab["cwd"] == "/new"));
    }

    #[test]
    fn a_failed_snapshot_never_becomes_an_authorization_view() {
        let mut state = Snapshots::default();
        assert!(state.answer(TREE, json!({"ok":false,"data":{"workspaces":[{"key":"other"}]}})).is_err());
        assert!(state.answer(PERSONAL, json!({"ok":true,"data":{"groups":[]}})).is_err());
        assert!(state.answer(LAYOUT, json!({"type":"error","error":{"code":"unavailable"}})).is_err());
        assert!(state.views.iter().all(Option::is_none));
    }

    #[test]
    fn unsupported_optional_layout_preserves_other_snapshots() {
        let mut state = Snapshots::default();
        state.answer(TREE, tree()).unwrap();
        state.answer(PERSONAL, json!({"ok":true,"data":{"groups":[],"workspaces":[]}})).unwrap();
        for error in [
            json!({"code":"operation.unsupported"}),
            json!("unknown variant `sidebar_layout.get`, expected a known operation"),
        ] {
            state.answer(LAYOUT, json!({"error":error})).unwrap();
            assert!(state.views[TREE].is_some());
            assert!(state.views[PERSONAL].is_some());
            assert!(state.views[LAYOUT].is_none());
            assert!(!state.dirty[LAYOUT]);
        }
    }

    #[tokio::test]
    async fn transient_snapshot_failure_ends_session_and_next_session_recovers() {
        let directory = tempfile::tempdir().unwrap();
        let socket = directory.path().join("daemon.sock");
        let listener = tokio::net::UnixListener::bind(&socket).unwrap();
        let published = Published::new();
        let server = tokio::spawn(async move {
            for fail in [true, false] {
                let (stream, _) = listener.accept().await.unwrap();
                let (read, mut write) = stream.into_split();
                let mut lines = BufReader::new(read).lines();
                while let Some(line) = lines.next_line().await.unwrap() {
                    let request: Value = serde_json::from_str(&line).unwrap();
                    let mut response = json!({"id":request["id"],"ok":true,"data":{}});
                    match request["id"].as_str().unwrap() {
                        "cache-tree" if fail => response["ok"] = json!(false),
                        "cache-tree" => {
                            response["data"] = tree()["data"].clone();
                        }
                        "cache-personal" => response["data"] = json!({"groups":[],"workspaces":[]}),
                        "cache-layout" => response["error"] = json!({"code":"operation.unsupported"}),
                        _ => {}
                    }
                    if write.write_all(format!("{response}\n").as_bytes()).await.is_err() {
                        break;
                    }
                    if request["id"] == "cache-tree" && fail {
                        // Keep the peer alive: only the cache recognizing this
                        // failure should end the connection, not fake EOF.
                        while lines.next_line().await.unwrap().is_some() {}
                        break;
                    }
                    if request["id"] == "cache-layout" {
                        return;
                    }
                }
            }
        });
        // A failure exits the subscription, so the owner enters its existing
        // reconnect backoff. The next session can publish without any event.
        let failed =
            tokio::time::timeout(Duration::from_secs(1), session(&socket, &published)).await.unwrap();
        assert!(failed.is_err());
        assert!(published.views.lock().unwrap()[TREE].is_none());
        let recovered = tokio::time::timeout(QUERY_WAIT, session(&socket, &published)).await.unwrap();
        assert!(recovered.is_err()); // fake daemon closes after its last answer
        {
            let views = published.views.lock().unwrap();
            assert!(views[TREE].is_some());
            assert!(views[PERSONAL].is_some());
            assert!(views[LAYOUT].is_none());
        }
        server.await.unwrap();
    }

    #[test]
    fn registry_replacement_refuses_old_authority() {
        let mut state = Snapshots {
            views: [Some(Arc::new(tree())), Some(Arc::new(json!({}))), Some(Arc::new(json!({})))],
            ..Default::default()
        };
        state
            .event(&json!({"event":"workspace-closed", "workspace":1,"registry_id":"other", "generation":1}))
            .unwrap();
        assert!(state.views.iter().all(Option::is_none));
    }
}
