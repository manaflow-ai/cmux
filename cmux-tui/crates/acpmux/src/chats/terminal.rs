//! Exact, read-only lookup for a terminal pane. A newly resumed chat can precede its index
//! notification. Look for that one file under the enabled roots without rescanning a root
//! (the metadata scanner is allowed to read an entire transcript).

use std::fs::{File, Metadata};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use cmux_chat_index::{AdapterKind, ChatKey, ChatRoot, RecordedRoots};
use serde_json::Value;

use super::{
    ChatService, ChatSettings, ChatSources, discover_roots, recorded_roots_path, resolve,
    settings_path,
};

pub(crate) struct Transcript {
    pub path: PathBuf,
    pub file: File,
    pub metadata: Metadata,
    pub title: Option<String>,
    pub created_ms: Option<i64>,
    pub updated_ms: Option<i64>,
}

fn jsonl_for(path: &Path, key: &ChatKey) -> bool {
    let Some(stem) = path.file_stem().and_then(|stem| stem.to_str()) else { return false };
    path.extension().is_some_and(|ext| ext == "jsonl")
        && match key.harness {
            AdapterKind::ClaudeCode => stem == key.session_id,
            AdapterKind::Codex => {
                stem.starts_with("rollout-") && stem.ends_with(&format!("-{}", key.session_id))
            }
            _ => false,
        }
}

impl ChatService {
    pub(crate) fn transcript_sources(&self) -> &ChatSources {
        &self.sources
    }
}

/// A hit in the metadata index avoids directory enumeration. During startup or a rescan use the
/// same root discovery and privacy settings as the index, without waiting for its scan lock.
pub(crate) fn locate(
    service: Option<&ChatService>,
    sources: &ChatSources,
    key: &ChatKey,
    cwd: Option<&Path>,
    read_dates: bool,
) -> Option<Transcript> {
    let (known, roots): (_, Vec<ChatRoot>) = match service.and_then(|s| s.state.try_lock().ok()) {
        Some(state) => {
            if !state.settings.enabled {
                return None;
            }
            let known = state.index.get(key).map(|chat| chat.entry.clone());
            let roots =
                state.index.roots().filter(|root| root.harness == key.harness).cloned().collect();
            (known, roots)
        }
        None => {
            let recorded = RecordedRoots::load(recorded_roots_path(sources));
            let settings = ChatSettings::load(&settings_path(sources));
            let (found, _) = discover_roots(sources, recorded.roots(), &settings);
            (None, found.roots.into_iter().filter(|root| root.harness == key.harness).collect())
        }
    };
    let mut file = known
        .as_ref()
        .map(|chat| chat.source_path.clone())
        .filter(|path| jsonl_for(path, key) && path.is_file());
    if file.is_none() {
        let mut projects = Vec::new();
        let mut sessions = Vec::new();
        for root in &roots {
            match root.harness {
                AdapterKind::ClaudeCode => projects.push(root.path.clone()),
                AdapterKind::Codex => sessions.push(root.path.join("sessions")),
                _ => {}
            }
        }
        file = match key.harness {
            AdapterKind::ClaudeCode => cwd.filter(|p| p.is_absolute()).and_then(|cwd| {
                let project = crate::adopt::project_dir_name(cwd);
                projects
                    .iter()
                    .map(|root| root.join(&project).join(format!("{}.jsonl", key.session_id)))
                    .find(|path| path.is_file())
            }),
            AdapterKind::Codex => codex_by_date(key, &sessions),
            _ => None,
        }
        .or_else(|| {
            resolve::find_on_disk(&key.session_id, &projects, &sessions).map(|(_, path)| path)
        });
    }
    let path = file?.canonicalize().ok()?;
    if !roots.iter().any(|root| path.starts_with(&root.real_path)) || !jsonl_for(&path, key) {
        return None;
    }
    let file = File::open(&path).ok()?;
    let metadata = file.metadata().ok()?;
    if !metadata.is_file() {
        return None;
    }
    let created_ms = known
        .as_ref()
        .and_then(|chat| chat.created_ms)
        .or_else(|| if read_dates { header_time(&file) } else { None });
    let updated_ms = known.as_ref().map(|chat| chat.updated_ms).or_else(|| {
        let time = metadata.modified().ok()?.duration_since(SystemTime::UNIX_EPOCH).ok()?;
        i64::try_from(time.as_millis()).ok()
    });
    Some(Transcript {
        path,
        file,
        metadata,
        title: known.and_then(|chat| chat.title),
        created_ms,
        updated_ms,
    })
}

/// Rollout folders use the local date. Its UTC day and the two neighboring days cover all
/// time zones, including a resume after a time zone change. Older IDs use the normal fallback.
fn codex_by_date(key: &ChatKey, sessions: &[PathBuf]) -> Option<PathBuf> {
    let id = uuid::Uuid::parse_str(&key.session_id).ok()?;
    if id.get_version_num() != 7 {
        return None;
    }
    let (seconds, nanos) = id.get_timestamp()?.to_unix();
    let day = chrono::DateTime::from_timestamp(i64::try_from(seconds).ok()?, nanos)?.date_naive();
    for day in [Some(day), day.pred_opt(), day.succ_opt()].into_iter().flatten() {
        let folder = day.format("%Y/%m/%d").to_string();
        for root in sessions {
            if let Ok(mut entries) = std::fs::read_dir(root.join(&folder))
                && let Some(path) = entries.find_map(|e| {
                    let entry = e.ok()?;
                    let path = entry.path();
                    (entry.file_type().ok()?.is_file() && jsonl_for(&path, key)).then_some(path)
                })
            {
                return Some(path);
            }
        }
    }
    None
}

/// Enough to reach the first dated record of an unindexed JSONL. A huge header leaves the
/// affordance undated until the normal index has its creation time.
fn header_time(file: &File) -> Option<i64> {
    let mut bytes = Vec::new();
    file.take(16 * 1024).read_to_end(&mut bytes).ok()?;
    bytes
        .split(|b| *b == b'\n')
        .filter_map(|line| serde_json::from_slice::<Value>(line).ok())
        .find_map(|record| {
            record
                .get("timestamp")
                .or_else(|| record.pointer("/payload/timestamp"))?
                .as_str()
                .and_then(cmux_chat_index::parse_rfc3339_ms)
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    #[test]
    fn terminal_agent_history_unindexed_uses_only_the_exact_file_in_an_enabled_root() {
        let home = tempfile::tempdir_in("/tmp").expect("synthetic home");
        let sources = ChatSources {
            home: home.path().to_owned(),
            acpmux_home: home.path().join("test-daemon-state"),
            env: Arc::new(|_| None),
            launch_roots: Vec::new(),
            user_roots: Vec::new(),
        };
        let key = ChatKey {
            harness: AdapterKind::ClaudeCode,
            session_id: "5b6c7d8e-9f0a-4b1c-8d2e-3f4a5b6c7d8e".into(),
        };
        let cwd = Path::new("/original/project");
        let dir = home.path().join(".claude/projects").join(crate::adopt::project_dir_name(cwd));
        std::fs::create_dir_all(&dir).expect("project store");
        let path = dir.join(format!("{}.jsonl", key.session_id));
        std::fs::write(&path, b"{\"timestamp\":\"2026-11-12T07:00:00Z\"}\n").expect("transcript");
        let file = locate(None, &sources, &key, Some(cwd), true).expect("cold lookup");
        assert_eq!(file.path, path.canonicalize().unwrap());
        assert_eq!(file.created_ms, cmux_chat_index::parse_rfc3339_ms("2026-11-12T07:00:00Z"));

        // Opening an older page does not probe the header again.
        assert_eq!(locate(None, &sources, &key, Some(cwd), false).unwrap().created_ms, None);

        // Turning off discovery removes the default store from the set of allowed roots.
        let settings = ChatSettings { discovery: false, ..ChatSettings::default() };
        std::fs::create_dir_all(&sources.acpmux_home).expect("daemon home");
        std::fs::write(settings_path(&sources), serde_json::to_vec(&settings).unwrap()).unwrap();
        assert!(locate(None, &sources, &key, Some(cwd), false).is_none());
    }
}
