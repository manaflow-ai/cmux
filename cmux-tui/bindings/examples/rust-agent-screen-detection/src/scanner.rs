//! Userland scanner for terminal-backed agent sessions.
//!
//! The daemon exposes generic terminal reads through the SDK. This module
//! owns the policy that turns those reads into agent events. It uses the
//! foreground process-group executable, not the shell leader, and keeps only
//! state transitions in the journal.
//!
//! The process-group and edge-trigger ideas are derived from herdr's
//! `src/pane.rs` and `src/pane/agent_detection.rs` at commit
//! `7b675f42af35508eab66ac42fe1598628597a893` (Apache-2.0), then adapted to
//! the cmux journal contract.

use std::collections::hash_map::DefaultHasher;
use std::collections::{HashMap, HashSet};
use std::hash::{Hash, Hasher};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux::{
    Client, Config, JournalAppendResult, JournalClass, JournalEventSchema, JournalIngress,
    JournalProducerManifest, JournalReplayPolicy, JournalSensitivity, JournalSubject,
    MutationOptions, ReadScreenOptions, Session, Terminal,
};
use serde_json::json;

use crate::detect::{AgentState, ScreenDetectTracker};
use crate::manifest::{DetectionInput, ManifestSet};
use crate::process as process_discovery;

const SCAN_INTERVAL: Duration = Duration::from_millis(100);
const RECONNECT_INTERVAL: Duration = Duration::from_secs(1);
const MANIFEST_RELOAD_INTERVAL: Duration = Duration::from_secs(5);
const PROCESS_GROUP_RESCAN_INTERVAL: Duration = Duration::from_millis(250);
const PROCESS_INFO_RECHECK_IDENTIFIED: Duration = Duration::from_secs(5);
const PROCESS_INFO_RECHECK_UNKNOWN: Duration = Duration::from_millis(500);
const PROCESS_INFO_RECHECK_ON_OUTPUT: Duration = Duration::from_secs(1);
const PLUGIN_VERSION: u32 = 1;

/// Runs until the daemon closes the socket or the process is terminated.
pub fn run(socket: &str, session_name: &str, plugin_id: &str) -> Result<(), String> {
    let plugin_generation =
        std::env::var("CMUX_PLUGIN_GENERATION").ok().filter(|value| !value.is_empty());
    loop {
        let config = Config::from_socket_path(socket);
        match Client::connect(config) {
            Ok(client) => {
                let session = client.current_session();
                if let Err(error) = register_manifest(&session, plugin_id) {
                    eprintln!("cmux-agent-screen-detection: manifest registration failed: {error}");
                    thread::sleep(RECONNECT_INTERVAL);
                    continue;
                }
                match scan_connection(&session, plugin_id, plugin_generation.as_deref()) {
                    Ok(()) => return Ok(()),
                    Err(error) => eprintln!(
                        "cmux-agent-screen-detection: {session_name} connection ended: {error}"
                    ),
                }
            }
            Err(error) => eprintln!("cmux-agent-screen-detection: connect failed: {error}"),
        }
        thread::sleep(RECONNECT_INTERVAL);
    }
}

fn register_manifest(session: &Session, plugin_id: &str) -> Result<(), String> {
    let namespace = format!("plugin.{plugin_id}");
    let manifest = JournalProducerManifest {
        producer_id: plugin_id.to_string(),
        namespace: namespace.clone(),
        manifest_version: PLUGIN_VERSION,
        max_sensitivity: JournalSensitivity::Sensitive,
        permissions: vec![format!("journal.append.{namespace}")],
        events: vec![
            event_schema(&format!("{namespace}.agent.state.changed")),
            event_schema(&format!("{namespace}.agent.session.ended")),
        ],
    };
    session
        .put_journal_producer_manifest(
            &manifest,
            MutationOptions::new(format!("manifest-{plugin_id}-{PLUGIN_VERSION}"))
                .map_err(|error| error.to_string())?,
        )
        .map(|_| ())
        .map_err(|error| error.to_string())
}

fn event_schema(kind: &str) -> JournalEventSchema {
    JournalEventSchema {
        kind: kind.to_string(),
        schema_version: 1,
        class: JournalClass::State,
        replay: JournalReplayPolicy::Required,
        sensitivity: JournalSensitivity::Sensitive,
        payload_schema: json!({
            "type":"object",
            "required":["format","plugin","adapter","event","normalized"],
            "properties":{
                "format":{"const":"cmux.agent-plugin.v1"},
                "plugin":{
                    "type":"object",
                    "required":["id","version"],
                    "properties":{"id":{"type":"string"},"version":{"type":"integer","minimum":1}},
                    "additionalProperties":false
                },
                "adapter":{
                    "type":"object",
                    "required":["id","version"],
                    "properties":{"id":{"type":"string"},"version":{"type":"integer","minimum":1}},
                    "additionalProperties":false
                },
                "event":{"enum":["state.changed","session.ended"]},
                "normalized":{
                    "type":"object",
                    "required":["state","source_session","observed_at_ms"],
                    "properties":{
                        "state":{"enum":["working","blocked","idle","done","unknown"]},
                        "source_session":{"type":"string"},
                        "plugin_generation":{"type":"string","pattern":"^[0-9]+$"},
                        "observed_at_ms":{"type":"string","pattern":"^[0-9]+$"}
                    },
                    "additionalProperties":false
                },
                "native":{"type":"object"}
            },
            "additionalProperties":false
        }),
    }
}

fn scan_connection(
    session: &Session,
    plugin_id: &str,
    plugin_generation: Option<&str>,
) -> Result<(), String> {
    let mut manifests = match ManifestSet::from_environment() {
        Ok(manifests) => manifests,
        Err(error) => {
            eprintln!("cmux-agent-screen-detection: optional manifest source ignored: {error}");
            ManifestSet::bundled().clone()
        }
    };
    let mut manifests_checked_at = Instant::now();
    let mut tracker = ScreenDetectTracker::default();
    let mut process_cache = ProcessGroupCache::default();
    let mut process_info_cache = ProcessInfoCache::default();
    // A connection nonce prevents two emissions in one millisecond from
    // sharing a key, while the sequence makes each attempted emission unique
    // even when the process and terminal stay unchanged.
    let emission_nonce = format!("{}-{}", std::process::id(), now_nanos());
    let mut emission_sequence = 0_u64;
    loop {
        let now = Instant::now();
        if now.duration_since(manifests_checked_at) >= MANIFEST_RELOAD_INTERVAL {
            match ManifestSet::from_environment() {
                Ok(next) => manifests = next,
                Err(error) => eprintln!(
                    "cmux-agent-screen-detection: keeping previous manifests after reload error: {error}"
                ),
            }
            manifests_checked_at = now;
        }
        let terminals = session.terminals().map_err(|error| error.to_string())?;
        let live_ids = terminals
            .iter()
            .filter_map(|terminal| terminal.id().map(|id| id.as_str().to_string()))
            .collect::<HashSet<_>>();
        tracker.retain_terminals(|terminal_id| live_ids.contains(terminal_id));
        process_cache.retain_terminals(|terminal_id| live_ids.contains(terminal_id));
        process_info_cache.retain_terminals(|terminal_id| live_ids.contains(terminal_id));
        for terminal in terminals {
            if let Err(error) = scan_terminal(
                &terminal,
                plugin_id,
                &manifests,
                &mut tracker,
                &mut process_cache,
                &mut process_info_cache,
                plugin_generation,
                &emission_nonce,
                &mut emission_sequence,
            ) {
                // A terminal may disappear between the catalog read and the
                // screen read. Keep scanning the remaining terminals.
                eprintln!("cmux-agent-screen-detection: terminal scan skipped: {error}");
            }
        }
        thread::sleep(SCAN_INTERVAL);
    }
}

#[derive(Debug, Default)]
struct ProcessGroupCache {
    entries: HashMap<String, CachedProcessGroup>,
}

#[derive(Debug, Default)]
struct ProcessInfoCache {
    entries: HashMap<String, CachedProcessInfo>,
}

#[derive(Debug, Clone)]
struct CachedProcessInfo {
    process: cmux::ProcessInfoResult,
    checked_at: Instant,
    stream_revision: Option<u64>,
    identified: bool,
}

impl ProcessInfoCache {
    fn get_or_refresh(
        &mut self,
        terminal: &Terminal,
        terminal_id: &str,
        stream_revision: Option<u64>,
        now: Instant,
    ) -> Result<cmux::ProcessInfoResult, String> {
        if let Some(cached) = self.entries.get(terminal_id)
            && !process_info_refresh_due(cached, stream_revision, now)
        {
            return Ok(cached.process.clone());
        }
        let process = terminal.process().map_err(|error| error.to_string())?;
        self.entries.insert(
            terminal_id.to_string(),
            CachedProcessInfo {
                process: process.clone(),
                checked_at: now,
                stream_revision,
                identified: false,
            },
        );
        Ok(process)
    }

    fn mark_identified(&mut self, terminal_id: &str, identified: bool) {
        if let Some(cached) = self.entries.get_mut(terminal_id) {
            cached.identified = identified;
        }
    }

    fn retain_terminals(&mut self, live: impl Fn(&str) -> bool) {
        self.entries.retain(|terminal_id, _| live(terminal_id));
    }
}

fn process_info_refresh_due(
    cached: &CachedProcessInfo,
    stream_revision: Option<u64>,
    now: Instant,
) -> bool {
    let revision_changed = matches!((cached.stream_revision, stream_revision), (Some(previous), Some(current)) if previous != current);
    let interval = if cached.identified {
        if revision_changed {
            PROCESS_INFO_RECHECK_ON_OUTPUT
        } else {
            PROCESS_INFO_RECHECK_IDENTIFIED
        }
    } else {
        PROCESS_INFO_RECHECK_UNKNOWN
    };
    now.duration_since(cached.checked_at) >= interval
}

#[derive(Debug, Clone)]
struct CachedProcessGroup {
    pid: u32,
    foreground_name: Option<String>,
    checked_at: Instant,
    job: process_discovery::ForegroundJob,
}

impl ProcessGroupCache {
    fn job_for(
        &mut self,
        terminal_id: &str,
        process: &cmux::ProcessInfoResult,
        now: Instant,
    ) -> process_discovery::ForegroundJob {
        let foreground_name = process.foreground_executable.clone();
        if let Some(cached) = self.entries.get(terminal_id)
            && cached.pid == process.pid
            && cached.foreground_name == foreground_name
            && now.duration_since(cached.checked_at) < PROCESS_GROUP_RESCAN_INTERVAL
        {
            return cached.job.clone();
        }
        let job = process_discovery::foreground_job(process.pid)
            .unwrap_or_else(|| process_discovery::fallback_job(process));
        self.entries.insert(
            terminal_id.to_string(),
            CachedProcessGroup {
                pid: process.pid,
                foreground_name,
                checked_at: now,
                job: job.clone(),
            },
        );
        job
    }

    fn retain_terminals(&mut self, live: impl Fn(&str) -> bool) {
        self.entries.retain(|terminal_id, _| live(terminal_id));
    }
}

fn scan_terminal(
    terminal: &Terminal,
    plugin_id: &str,
    manifests: &ManifestSet,
    tracker: &mut ScreenDetectTracker,
    process_cache: &mut ProcessGroupCache,
    process_info_cache: &mut ProcessInfoCache,
    plugin_generation: Option<&str>,
    emission_nonce: &str,
    emission_sequence: &mut u64,
) -> Result<(), String> {
    let snapshot = terminal.refresh().map_err(|error| error.to_string())?;
    let terminal_id = terminal
        .id()
        .ok_or_else(|| "terminal selector did not resolve to an id".to_string())?
        .as_str()
        .to_string();
    if !snapshot.running {
        // A terminal can remain in the catalog briefly after its PTY exits.
        // Close the plugin-owned emission now instead of waiting for catalog
        // pruning, so the roster does not show a dead agent during that gap.
        if let Some(emission) =
            tracker.record_detection_at(&terminal_id, None, Instant::now(), true, true)
        {
            // The process query is expected to fail after a PTY exits. Keep
            // the terminal identity as the source session for this final
            // event instead of issuing a second, racy process read.
            append_emission(
                terminal,
                plugin_id,
                plugin_generation,
                &emission,
                None,
                emission_nonce,
                emission_sequence,
            )?;
        }
        return Ok(());
    }
    let now = Instant::now();
    let process =
        process_info_cache.get_or_refresh(terminal, &terminal_id, snapshot.stream_revision, now)?;
    let job = process_cache.job_for(&terminal_id, &process, now);
    // `stream_revision` is a cheap coalesced PTY counter. New daemons expose
    // it on the terminal snapshot, so unchanged screens do not cross the
    // socket or invoke the terminal parser. Older daemons fall back to a
    // local text hash below.
    let revision_due = snapshot
        .stream_revision
        .map(|revision| tracker.observe_revision(&terminal_id, revision, now));
    let manifest = process_discovery::identify_job(manifests, &job)
        .map(|(manifest, _)| manifest)
        .or_else(|| {
            process
                .foreground_executable
                .as_deref()
                .or(process.executable.as_deref())
                .or_else(|| process.argv.first().map(String::as_str))
                .and_then(|name| manifests.identify(name))
        });
    let identity_edge = tracker.note_foreground_job_at(
        &terminal_id,
        manifest.map(|item| item.id()),
        Some(job.process_group_id),
        now,
    );
    process_info_cache.mark_identified(&terminal_id, manifest.is_some());
    if manifest.is_none() {
        // Process inspection is best effort. The tracker keeps a known agent
        // through a bounded miss-confirmation window, so do not emit Done or
        // read a stale screen until it confirms the identity disappeared.
        if tracker.foreground_agent(&terminal_id).is_some() {
            return Ok(());
        }
        if !identity_edge {
            return Ok(());
        }
        if let Some(emission) =
            tracker.record_detection_at(&terminal_id, None, now, identity_edge, true)
        {
            append_emission(
                terminal,
                plugin_id,
                plugin_generation,
                &emission,
                Some(process.pid),
                emission_nonce,
                emission_sequence,
            )?;
        }
        return Ok(());
    }

    // Process identity is enough to publish presence immediately. During the
    // startup grace window, do not read the viewport because it can still be
    // the shell's old prompt or the previous agent's screen. The first
    // post-grace read is forced even when the PTY revision did not change.
    if identity_edge {
        let agent = manifest.expect("checked above").id();
        if let Some(emission) = tracker.record_identity_presence_at(&terminal_id, agent, now) {
            append_emission(
                terminal,
                plugin_id,
                plugin_generation,
                &emission,
                Some(process.pid),
                emission_nonce,
                emission_sequence,
            )?;
        }
    }
    let grace_finished = tracker.finish_startup_grace(&terminal_id, now);
    if tracker.startup_grace_active(&terminal_id, now) {
        return Ok(());
    }
    if revision_due == Some(false) && !identity_edge && !grace_finished {
        return Ok(());
    }
    let screen = terminal.read_screen(ReadScreenOptions).map_err(|error| error.to_string())?;
    if snapshot.stream_revision.is_none() {
        let mut hasher = DefaultHasher::new();
        screen.text.hash(&mut hasher);
        let revision = hasher.finish();
        let due = tracker.observe_revision(&terminal_id, revision, now);
        if !due && !identity_edge {
            return Ok(());
        }
    }
    let manifest = manifest.expect("checked above");
    let mut detection = manifest.detect(DetectionInput {
        screen: &screen.text,
        osc_title: snapshot.title.as_str(),
        osc_progress: screen.osc_progress.as_deref().unwrap_or_default(),
    });
    // Flowing PTY output is a working signal for the screen source. It only
    // upgrades an idle read and owes one expiry re-evaluation; hooks still
    // win in the core roster reducer.
    if !detection.skip_state_update
        && detection.state == crate::manifest::ScreenState::Idle
        && tracker.output_active(&terminal_id, now)
    {
        detection.state = crate::manifest::ScreenState::Working;
        tracker.note_activity_upgrade(&terminal_id);
    }
    if let Some(emission) = tracker.record_detection_at(
        &terminal_id,
        Some((manifest.id(), detection)),
        now,
        identity_edge,
        false,
    ) {
        append_emission(
            terminal,
            plugin_id,
            plugin_generation,
            &emission,
            Some(process.pid),
            emission_nonce,
            emission_sequence,
        )?;
    }
    Ok(())
}

fn append_emission(
    terminal: &Terminal,
    plugin_id: &str,
    plugin_generation: Option<&str>,
    emission: &crate::detect::ScreenDetectEmission,
    process_pid: Option<u32>,
    emission_nonce: &str,
    emission_sequence: &mut u64,
) -> Result<JournalAppendResult, String> {
    let terminal_id = terminal
        .id()
        .ok_or_else(|| "terminal selector did not resolve to an id".to_string())?
        .as_str()
        .to_string();
    let namespace = format!("plugin.{plugin_id}");
    let event_name =
        if emission.state == AgentState::Done { "session.ended" } else { "state.changed" };
    let kind = format!("{namespace}.agent.{event_name}");
    let observed_at_ms = now_ms();
    let source_session = process_pid
        .map(|pid| format!("pid:{pid}"))
        .unwrap_or_else(|| format!("terminal:{terminal_id}"));
    let mut normalized = json!({
        "state":emission.state.as_str(),
        "source_session":source_session,
        "observed_at_ms":observed_at_ms.to_string(),
    });
    if let Some(generation) = plugin_generation {
        normalized["plugin_generation"] = json!(generation);
    }
    let idempotency_key = emission_idempotency_key(emission_nonce, *emission_sequence);
    *emission_sequence = (*emission_sequence).saturating_add(1);
    let ingress = JournalIngress {
        producer_id: plugin_id.to_string(),
        manifest_version: PLUGIN_VERSION,
        kind,
        schema_version: 1,
        occurred_at_ms: Some(observed_at_ms),
        subjects: vec![JournalSubject { kind: "terminal".into(), id: terminal_id.clone() }],
        sensitivity: Some(JournalSensitivity::Sensitive),
        payload: json!({
            "format":"cmux.agent-plugin.v1",
            "plugin":{"id":plugin_id,"version":PLUGIN_VERSION},
            "adapter":{"id":emission.agent,"version":1},
            "event":event_name,
            "normalized":normalized,
            "native":{
                "engine":"herdr-manifest-v3",
                "matched_rule":emission.matched_rule,
                "visible":{
                    "idle":emission.visible_idle,
                    "blocker":emission.visible_blocker,
                    "working":emission.visible_working
                }
            },
        }),
        causation_id: None,
        correlation_id: None,
    };
    terminal
        .session()
        .append_journal_event(
            &ingress,
            MutationOptions::new(idempotency_key).map_err(|error| error.to_string())?,
        )
        .map(|result| result.value)
        .map_err(|error| error.to_string())
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as u64)
        .unwrap_or_default()
}

fn now_nanos() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or_default()
}

fn emission_idempotency_key(nonce: &str, sequence: u64) -> String {
    format!("agent-emission-{nonce}-{sequence}")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cached(
        checked_at: Instant,
        identified: bool,
        stream_revision: Option<u64>,
    ) -> CachedProcessInfo {
        CachedProcessInfo {
            process: cmux::ProcessInfoResult {
                pid: 42,
                executable: Some("shell".into()),
                argv: vec!["shell".into()],
                cwd: None,
                foreground_cwd: None,
                foreground_executable: Some("shell".into()),
                children: Vec::new(),
            },
            checked_at,
            stream_revision,
            identified,
        }
    }

    #[test]
    fn identified_processes_use_a_long_quiet_recheck_interval() {
        let start = Instant::now();
        let entry = cached(start, true, Some(7));
        assert!(!process_info_refresh_due(
            &entry,
            Some(7),
            start + PROCESS_INFO_RECHECK_IDENTIFIED - Duration::from_millis(1),
        ));
        assert!(
            process_info_refresh_due(&entry, Some(7), start + PROCESS_INFO_RECHECK_IDENTIFIED,)
        );
    }

    #[test]
    fn output_changes_make_identified_processes_recheck_within_one_second() {
        let start = Instant::now();
        let entry = cached(start, true, Some(7));
        assert!(!process_info_refresh_due(
            &entry,
            Some(8),
            start + PROCESS_INFO_RECHECK_ON_OUTPUT - Duration::from_millis(1),
        ));
        assert!(process_info_refresh_due(&entry, Some(8), start + PROCESS_INFO_RECHECK_ON_OUTPUT,));
    }

    #[test]
    fn unknown_processes_recheck_quickly_for_spawn_detection() {
        let start = Instant::now();
        let entry = cached(start, false, Some(7));
        assert!(!process_info_refresh_due(
            &entry,
            Some(8),
            start + PROCESS_INFO_RECHECK_UNKNOWN - Duration::from_millis(1),
        ));
        assert!(process_info_refresh_due(&entry, Some(8), start + PROCESS_INFO_RECHECK_UNKNOWN,));
    }

    #[test]
    fn emission_keys_are_unique_for_one_connection() {
        let first = emission_idempotency_key("17-123456789", 0);
        let second = emission_idempotency_key("17-123456789", 1);
        assert_ne!(first, second);
        assert!(first.len() <= 128);
        assert!(second.len() <= 128);
    }
}
