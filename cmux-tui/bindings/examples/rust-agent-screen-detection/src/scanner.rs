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
    MutationOptions, ReadScreenOptions, Selector, Session, SessionId, Terminal,
};
use serde_json::json;

use crate::detect::{AgentState, ScreenDetectTracker};
use crate::manifest::{DetectionInput, ManifestSet};
use crate::process as process_discovery;

const SCAN_INTERVAL: Duration = Duration::from_millis(100);
const RECONNECT_INTERVAL: Duration = Duration::from_secs(1);
const MANIFEST_RELOAD_INTERVAL: Duration = Duration::from_secs(5);
const PROCESS_GROUP_RECHECK_IDENTIFIED: Duration = Duration::from_secs(5);
const PROCESS_GROUP_RECHECK_UNKNOWN: Duration = Duration::from_millis(500);
const PROCESS_GROUP_RECHECK_ON_OUTPUT: Duration = Duration::from_secs(1);
const PROCESS_INFO_RECHECK_IDENTIFIED: Duration = Duration::from_secs(5);
const PROCESS_INFO_RECHECK_UNKNOWN: Duration = Duration::from_millis(500);
const PROCESS_INFO_RECHECK_ON_OUTPUT: Duration = Duration::from_secs(1);
const PROCESS_ACQUISITION_FAST_WINDOW: Duration = Duration::from_millis(1_500);
const PROCESS_ACQUISITION_WINDOW: Duration = Duration::from_secs(8);
const PROCESS_ACQUISITION_FAST_RECHECK: Duration = Duration::from_millis(500);
const PROCESS_ACQUISITION_SLOW_RECHECK: Duration = Duration::from_secs(2);
const RETRY_BACKOFF_MIN: Duration = Duration::from_millis(250);
const RETRY_BACKOFF_MAX: Duration = Duration::from_secs(5);
const PLUGIN_VERSION: u32 = 1;

/// An exact journal request retained after an uncertain transport outcome.
/// Keeping the envelope and key together is required by the journal's
/// idempotency contract: rebuilding it later would change its fingerprint.
#[derive(Clone, Debug)]
struct PendingAppend {
    emission: crate::detect::ScreenDetectEmission,
    ingress: JournalIngress,
    idempotency_key: String,
    attempts: u32,
    retry_not_before: Instant,
}

#[derive(Debug)]
struct ScannerState {
    tracker: ScreenDetectTracker,
    process_cache: ProcessGroupCache,
    process_info_cache: ProcessInfoCache,
    pending_appends: HashMap<String, PendingAppend>,
    emission_nonce: String,
    emission_sequence: u64,
}

impl ScannerState {
    fn new() -> Self {
        Self {
            tracker: ScreenDetectTracker::default(),
            process_cache: ProcessGroupCache::default(),
            process_info_cache: ProcessInfoCache::default(),
            pending_appends: HashMap::new(),
            emission_nonce: format!("{}-{}", std::process::id(), now_nanos()),
            emission_sequence: 0,
        }
    }

    fn retain_terminals(&mut self, live: &HashSet<String>) {
        // Keep the in-memory tracker and probe caches for an uncertain
        // envelope until replay settles it. Otherwise a later successful
        // replay would be followed by a duplicate identity edge.
        let mut retained = live.clone();
        retained.extend(self.pending_appends.keys().cloned());
        self.tracker.retain_terminals(|terminal_id| retained.contains(terminal_id));
        self.process_cache.retain_terminals(|terminal_id| retained.contains(terminal_id));
        self.process_info_cache.retain_terminals(|terminal_id| retained.contains(terminal_id));
        // Pending appends are exact journal envelopes. They can have been
        // committed even when this catalog snapshot briefly omits a terminal,
        // so the replay path owns their lifetime instead of catalog pruning.
    }
}

#[derive(Debug)]
enum AppendError {
    Definite(String),
    Uncertain(String),
}

impl AppendError {
    fn message(&self) -> &str {
        match self {
            Self::Definite(message) | Self::Uncertain(message) => message,
        }
    }

    fn is_uncertain(&self) -> bool {
        matches!(self, Self::Uncertain(_))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum PublishResult {
    Committed,
    Deferred,
}

/// Runs until the daemon closes the socket or the process is terminated.
pub fn run(socket: &str, session_name: &str, plugin_id: &str) -> Result<(), String> {
    let plugin_generation =
        std::env::var("CMUX_PLUGIN_GENERATION").ok().filter(|value| !value.is_empty());
    let session_selector = configured_session_selector(session_name)?;
    let mut state = ScannerState::new();
    loop {
        let config = Config::from_socket_path(socket);
        match Client::connect(config) {
            Ok(client) => {
                let session = client.session(session_selector.clone());
                if let Err(error) = register_manifest(&session, plugin_id) {
                    eprintln!("cmux-agent-screen-detection: manifest registration failed: {error}");
                    thread::sleep(RECONNECT_INTERVAL);
                    continue;
                }
                match scan_connection(&session, plugin_id, plugin_generation.as_deref(), &mut state)
                {
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

fn configured_session_selector(_session_name: &str) -> Result<Selector<SessionId>, String> {
    Ok(Selector::current())
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
    state: &mut ScannerState,
) -> Result<(), String> {
    let mut manifests = match ManifestSet::from_environment() {
        Ok(manifests) => manifests,
        Err(error) => {
            eprintln!("cmux-agent-screen-detection: optional manifest source ignored: {error}");
            ManifestSet::bundled().clone()
        }
    };
    let mut manifests_checked_at = Instant::now();
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
        // `terminal.list` already returns complete snapshots. Keep that one
        // bulk response instead of refreshing every handle and creating an
        // N+1 socket request pattern on large sessions.
        let snapshots = session.terminal_snapshots().map_err(|error| error.to_string())?;
        let live_ids = snapshots
            .iter()
            .map(|snapshot| snapshot.id.as_str().to_string())
            .collect::<HashSet<_>>();
        retry_pending_appends_without_live_terminal(
            session,
            &live_ids,
            &mut state.tracker,
            &mut state.pending_appends,
        );
        state.retain_terminals(&live_ids);
        for snapshot in snapshots {
            let terminal = session.terminal(snapshot.id.clone());
            if let Err(error) =
                scan_terminal(&terminal, &snapshot, plugin_id, &manifests, plugin_generation, state)
            {
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
    /// Short adaptive probing after an agent is first found catches a
    /// hand-off or same-name replacement without making steady-state scans
    /// expensive.
    acquisition_started_at: Option<Instant>,
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
        let (identified, acquisition_started_at) = self
            .entries
            .get(terminal_id)
            .map(|entry| (entry.identified, entry.acquisition_started_at))
            .unwrap_or((false, None));
        self.entries.insert(
            terminal_id.to_string(),
            CachedProcessInfo {
                process: process.clone(),
                checked_at: now,
                stream_revision,
                // Preserve the acquisition phase across refreshes. The
                // scanner marks this value after it identifies the new
                // process; resetting it here would make a steady agent pay
                // the fast probe cost forever.
                identified,
                acquisition_started_at,
            },
        );
        Ok(process)
    }

    fn mark_identified(&mut self, terminal_id: &str, identified: bool, now: Instant) {
        if let Some(cached) = self.entries.get_mut(terminal_id) {
            if identified && !cached.identified {
                cached.acquisition_started_at = Some(now);
            }
            if !identified {
                cached.acquisition_started_at = None;
            }
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
    // Older daemons do not expose a stream revision. Keep a bounded one-second
    // probe in that mode because a same-name process replacement cannot be
    // observed through output metadata.
    let output_signal_missing = cached.stream_revision.is_none() || stream_revision.is_none();
    let interval = if cached.identified {
        if revision_changed || output_signal_missing {
            PROCESS_INFO_RECHECK_ON_OUTPUT
        } else if let Some(started_at) = cached.acquisition_started_at {
            let acquisition_age = now.duration_since(started_at);
            if acquisition_age < PROCESS_ACQUISITION_FAST_WINDOW {
                PROCESS_ACQUISITION_FAST_RECHECK
            } else if acquisition_age < PROCESS_ACQUISITION_WINDOW {
                PROCESS_ACQUISITION_SLOW_RECHECK
            } else {
                PROCESS_INFO_RECHECK_IDENTIFIED
            }
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
    stream_revision: Option<u64>,
    job: process_discovery::ForegroundJob,
    /// A public process response is a useful fallback, but its pid is not a
    /// verified foreground process-group id and must not create replacement
    /// edges.
    authoritative: bool,
    identified: bool,
    acquisition_started_at: Option<Instant>,
}

impl ProcessGroupCache {
    fn job_for(
        &mut self,
        terminal_id: &str,
        process: &cmux::ProcessInfoResult,
        stream_revision: Option<u64>,
        now: Instant,
    ) -> process_discovery::ForegroundJob {
        let foreground_name = process.foreground_executable.clone();
        if let Some(cached) = self.entries.get(terminal_id)
            && cached.pid == process.pid
            && cached.foreground_name == foreground_name
            && !process_group_refresh_due(cached, stream_revision, now)
        {
            return cached.job.clone();
        }
        let (identified, acquisition_started_at) = self
            .entries
            .get(terminal_id)
            .map(|entry| (entry.identified, entry.acquisition_started_at))
            .unwrap_or((false, None));
        let native_job = process_discovery::foreground_job(process.pid);
        let authoritative = native_job.is_some();
        let job = native_job.unwrap_or_else(|| process_discovery::fallback_job(process));
        self.entries.insert(
            terminal_id.to_string(),
            CachedProcessGroup {
                pid: process.pid,
                foreground_name,
                checked_at: now,
                stream_revision,
                job: job.clone(),
                authoritative,
                identified,
                acquisition_started_at,
            },
        );
        job
    }

    fn mark_identified(&mut self, terminal_id: &str, identified: bool, now: Instant) {
        if let Some(cached) = self.entries.get_mut(terminal_id) {
            if identified && !cached.identified {
                cached.acquisition_started_at = Some(now);
            }
            if !identified {
                cached.acquisition_started_at = None;
            }
            cached.identified = identified;
        }
    }

    fn authoritative_group_id(&self, terminal_id: &str) -> Option<u32> {
        self.entries
            .get(terminal_id)
            .filter(|entry| entry.authoritative)
            .map(|entry| entry.job.process_group_id)
    }

    fn retain_terminals(&mut self, live: impl Fn(&str) -> bool) {
        self.entries.retain(|terminal_id, _| live(terminal_id));
    }
}

fn process_group_refresh_due(
    cached: &CachedProcessGroup,
    stream_revision: Option<u64>,
    now: Instant,
) -> bool {
    let revision_changed = matches!((cached.stream_revision, stream_revision), (Some(previous), Some(current)) if previous != current);
    let output_signal_missing = cached.stream_revision.is_none() || stream_revision.is_none();
    let interval = if cached.identified {
        if revision_changed || output_signal_missing {
            PROCESS_GROUP_RECHECK_ON_OUTPUT
        } else if let Some(started_at) = cached.acquisition_started_at {
            let acquisition_age = now.duration_since(started_at);
            if acquisition_age < PROCESS_ACQUISITION_FAST_WINDOW {
                PROCESS_ACQUISITION_FAST_RECHECK
            } else if acquisition_age < PROCESS_ACQUISITION_WINDOW {
                PROCESS_ACQUISITION_SLOW_RECHECK
            } else {
                PROCESS_GROUP_RECHECK_IDENTIFIED
            }
        } else {
            PROCESS_GROUP_RECHECK_IDENTIFIED
        }
    } else {
        PROCESS_GROUP_RECHECK_UNKNOWN
    };
    now.duration_since(cached.checked_at) >= interval
}

fn scan_terminal(
    terminal: &Terminal,
    snapshot: &cmux::TerminalSnapshot,
    plugin_id: &str,
    manifests: &ManifestSet,
    plugin_generation: Option<&str>,
    state: &mut ScannerState,
) -> Result<(), String> {
    let terminal_id = snapshot.id.as_str().to_string();
    // A transport failure after dispatch leaves the mutation outcome
    // uncertain. Replay the retained envelope before taking a new process or
    // screen sample, otherwise a newer edge could overtake the old one.
    if retry_pending_append(
        terminal.session(),
        &terminal_id,
        &mut state.tracker,
        &mut state.pending_appends,
    )? {
        return Ok(());
    }
    let now = Instant::now();
    if !snapshot.running {
        // A terminal can remain in the catalog briefly after its PTY exits.
        // Close the plugin-owned emission now instead of waiting for catalog
        // pruning, so the roster does not show a dead agent during that gap.
        if let Some(emission) = state.tracker.record_detection_at_with_revision(
            &terminal_id,
            None,
            now,
            true,
            true,
            snapshot.stream_revision,
        ) {
            // The process query is expected to fail after a PTY exits. Keep
            // the terminal identity as the source session for this final
            // event instead of issuing a second, racy process read.
            if publish_emission(terminal, plugin_id, plugin_generation, &emission, None, state)?
                == PublishResult::Deferred
            {
                return Ok(());
            }
        }
        return Ok(());
    }
    let process = state.process_info_cache.get_or_refresh(
        terminal,
        &terminal_id,
        snapshot.stream_revision,
        now,
    )?;
    let job = state.process_cache.job_for(&terminal_id, &process, snapshot.stream_revision, now);
    // `stream_revision` is a cheap coalesced PTY counter. New daemons expose
    // it on the terminal snapshot, so unchanged screens do not cross the
    // socket or invoke the terminal parser. Older daemons fall back to a
    // local text hash below.
    let revision_due = snapshot
        .stream_revision
        .map(|revision| state.tracker.observe_revision(&terminal_id, revision, now));
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
    let process_group_id = state.process_cache.authoritative_group_id(&terminal_id);
    let identity_edge = state.tracker.note_foreground_job_at_with_revision(
        &terminal_id,
        manifest.map(|item| item.id()),
        process_group_id,
        snapshot.stream_revision,
        now,
    );
    state.process_cache.mark_identified(&terminal_id, manifest.is_some(), now);
    state.process_info_cache.mark_identified(&terminal_id, manifest.is_some(), now);
    if manifest.is_none() {
        // Process inspection is best effort. The tracker keeps a known agent
        // through a bounded miss-confirmation window, so do not emit Done or
        // read a stale screen until it confirms the identity disappeared.
        if state.tracker.foreground_agent(&terminal_id).is_some() {
            return Ok(());
        }
        if !identity_edge {
            return Ok(());
        }
        if let Some(emission) = state.tracker.record_detection_at_with_revision(
            &terminal_id,
            None,
            now,
            identity_edge,
            true,
            snapshot.stream_revision,
        ) && publish_emission(
            terminal,
            plugin_id,
            plugin_generation,
            &emission,
            Some(process.pid),
            state,
        )? == PublishResult::Deferred
        {
            return Ok(());
        }
        return Ok(());
    }

    // Process identity is enough to publish presence immediately. During the
    // startup grace window, do not read the viewport because it can still be
    // the shell's old prompt or the previous agent's screen. The first
    // post-grace read is forced even when the PTY revision did not change.
    let agent = manifest.expect("checked above").id();
    if (identity_edge || state.tracker.needs_identity_presence(&terminal_id, agent))
        && let Some(emission) = state.tracker.record_identity_presence_at(&terminal_id, agent, now)
        && publish_emission(
            terminal,
            plugin_id,
            plugin_generation,
            &emission,
            Some(process.pid),
            state,
        )? == PublishResult::Deferred
    {
        return Ok(());
    }
    let grace_finished = state.tracker.finish_startup_grace(&terminal_id, now);
    if state.tracker.startup_grace_active(&terminal_id, now) {
        return Ok(());
    }
    if revision_due == Some(false) && !identity_edge && !grace_finished {
        return Ok(());
    }
    let screen = terminal.read_screen(ReadScreenOptions).map_err(|error| error.to_string())?;
    // Keep the host revision separate from the local text hash. The hash is
    // only a scheduling fallback; it is not evidence that retained OSC
    // metadata belongs to the current process.
    let metadata_revision = merged_stream_revision(snapshot.stream_revision, screen.revision);
    let mut evaluation_revision = metadata_revision;
    if evaluation_revision.is_none() {
        let mut hasher = DefaultHasher::new();
        screen.text.hash(&mut hasher);
        evaluation_revision = Some(hasher.finish());
    }
    let revision_due_after_read = evaluation_revision
        .map(|revision| state.tracker.observe_revision(&terminal_id, revision, now));
    if snapshot.stream_revision.is_none()
        && revision_due_after_read == Some(false)
        && !identity_edge
    {
        return Ok(());
    }
    let manifest = manifest.expect("checked above");
    // The daemon exposes OSC title and progress as generic terminal
    // metadata. It can retain those values across a foreground-process
    // change, so the userland plugin fences replacement agents until a
    // post-edge output revision. The first acquisition deliberately keeps
    // evidence already emitted by the new agent, matching herdr's behavior.
    // Older daemons do not expose revisions, and a terminal with no known
    // fence keeps the compatibility path. A known fence fails closed while
    // the current host revision is missing.
    // A screen read can carry the first revision on hosts whose catalog
    // snapshot did not. Enrich a replacement fence after the read before
    // consulting OSC fields, closing that compatibility race without a daemon
    // change. First acquisition remains intentionally unfenced.
    let _ = state.tracker.note_foreground_job_at_with_revision(
        &terminal_id,
        Some(agent),
        process_group_id,
        metadata_revision,
        now,
    );
    let metadata_fresh = state.tracker.metadata_is_fresh(&terminal_id, metadata_revision);
    let osc_title = if metadata_fresh { snapshot.title.as_str() } else { "" };
    let osc_progress =
        if metadata_fresh { screen.osc_progress.as_deref().unwrap_or_default() } else { "" };
    let mut detection =
        manifest.detect(DetectionInput { screen: &screen.text, osc_title, osc_progress });
    // Flowing PTY output is a working signal for the screen source. It only
    // upgrades an idle read and owes one expiry re-evaluation; hooks still
    // win in the core roster reducer.
    if !detection.skip_state_update
        && detection.state == crate::manifest::ScreenState::Idle
        && state.tracker.output_active(&terminal_id, now)
    {
        detection.state = crate::manifest::ScreenState::Working;
        state.tracker.note_activity_upgrade(&terminal_id);
    }
    if let Some(emission) = state.tracker.record_detection_at(
        &terminal_id,
        Some((manifest.id(), detection)),
        now,
        identity_edge,
        false,
    ) && publish_emission(
        terminal,
        plugin_id,
        plugin_generation,
        &emission,
        Some(process.pid),
        state,
    )? == PublishResult::Deferred
    {
        return Ok(());
    }
    Ok(())
}

fn prepare_emission(
    terminal: &Terminal,
    plugin_id: &str,
    plugin_generation: Option<&str>,
    emission: &crate::detect::ScreenDetectEmission,
    process_pid: Option<u32>,
    emission_nonce: &str,
    emission_sequence: &mut u64,
) -> Result<PendingAppend, String> {
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
    Ok(PendingAppend {
        emission: emission.clone(),
        ingress,
        idempotency_key,
        attempts: 0,
        retry_not_before: Instant::now(),
    })
}

fn append_prepared(
    session: &Session,
    pending: &PendingAppend,
) -> Result<JournalAppendResult, AppendError> {
    let mutation = MutationOptions::new(pending.idempotency_key.clone())
        .map_err(|error| AppendError::Definite(error.to_string()))?;
    session.append_journal_event(&pending.ingress, mutation).map(|result| result.value).map_err(
        |error| {
            let uncertain = matches!(&error, cmux::Error::MutationTransport { .. });
            let message = error.to_string();
            if uncertain { AppendError::Uncertain(message) } else { AppendError::Definite(message) }
        },
    )
}

fn retry_backoff(attempts: u32) -> Duration {
    match attempts {
        0 | 1 => RETRY_BACKOFF_MIN,
        2 => Duration::from_millis(500),
        3 => Duration::from_secs(1),
        4 => Duration::from_secs(2),
        _ => RETRY_BACKOFF_MAX,
    }
}

/// Retry one retained envelope before the scanner observes a newer state.
/// Returns `true` while the terminal remains blocked on that retry.
fn retry_pending_append(
    session: &Session,
    terminal_id: &str,
    tracker: &mut ScreenDetectTracker,
    pending_appends: &mut HashMap<String, PendingAppend>,
) -> Result<bool, String> {
    let Some(pending) = pending_appends.get(terminal_id).cloned() else {
        return Ok(false);
    };
    if Instant::now() < pending.retry_not_before {
        return Ok(true);
    }
    match append_prepared(session, &pending) {
        Ok(_) => {
            pending_appends.remove(terminal_id);
            tracker.commit_emission(&pending.emission);
            Ok(false)
        }
        Err(error) if error.is_uncertain() => {
            if let Some(current) = pending_appends.get_mut(terminal_id) {
                current.attempts = current.attempts.saturating_add(1);
                current.retry_not_before = Instant::now() + retry_backoff(current.attempts);
            }
            eprintln!(
                "cmux-agent-screen-detection: journal append uncertain for {terminal_id}; retrying: {}",
                error.message()
            );
            Ok(true)
        }
        Err(error) => {
            pending_appends.remove(terminal_id);
            tracker.discard_emission(&pending.emission);
            Err(error.message().to_string())
        }
    }
}

/// Retry exact envelopes for terminals absent from one catalog snapshot. A
/// terminal list can race with PTY closure or recreation; dropping the
/// envelope here would either lose a committed edge or publish a duplicate
/// edge with a new idempotency key when the terminal returns.
fn retry_pending_appends_without_live_terminal(
    session: &Session,
    live_ids: &HashSet<String>,
    tracker: &mut ScreenDetectTracker,
    pending_appends: &mut HashMap<String, PendingAppend>,
) {
    let absent_ids = pending_appends
        .keys()
        .filter(|terminal_id| !live_ids.contains(*terminal_id))
        .cloned()
        .collect::<Vec<_>>();
    for terminal_id in absent_ids {
        if let Err(error) = retry_pending_append(session, &terminal_id, tracker, pending_appends) {
            eprintln!(
                "cmux-agent-screen-detection: dropping pending journal append for {terminal_id}: {error}"
            );
        }
    }
}

/// Publish one edge and commit the tracker's in-memory state only after the
/// journal accepts it. An uncertain transport result keeps the exact request
/// for idempotent replay.
fn publish_emission(
    terminal: &Terminal,
    plugin_id: &str,
    plugin_generation: Option<&str>,
    emission: &crate::detect::ScreenDetectEmission,
    process_pid: Option<u32>,
    state: &mut ScannerState,
) -> Result<PublishResult, String> {
    let terminal_id = emission.terminal_id.clone();
    if let Some(existing) = state.pending_appends.get(&terminal_id) {
        if existing.emission != *emission {
            return Err(format!(
                "terminal {terminal_id} has a different journal emission waiting for replay"
            ));
        }
    } else {
        let pending = match prepare_emission(
            terminal,
            plugin_id,
            plugin_generation,
            emission,
            process_pid,
            &state.emission_nonce,
            &mut state.emission_sequence,
        ) {
            Ok(pending) => pending,
            Err(error) => {
                state.tracker.rollback_emission(emission);
                state.tracker.discard_emission(emission);
                return Err(error);
            }
        };
        state.pending_appends.insert(terminal_id.clone(), pending);
    }
    let pending = state
        .pending_appends
        .get(&terminal_id)
        .cloned()
        .expect("pending emission was inserted above");
    match append_prepared(terminal.session(), &pending) {
        Ok(_) => {
            state.pending_appends.remove(&terminal_id);
            state.tracker.commit_emission(emission);
            Ok(PublishResult::Committed)
        }
        Err(error) => {
            state.tracker.rollback_emission(emission);
            if error.is_uncertain() {
                if let Some(current) = state.pending_appends.get_mut(&terminal_id) {
                    current.attempts = current.attempts.saturating_add(1);
                    current.retry_not_before = Instant::now() + retry_backoff(current.attempts);
                }
                eprintln!(
                    "cmux-agent-screen-detection: journal append uncertain for {terminal_id}; retrying: {}",
                    error.message()
                );
                Ok(PublishResult::Deferred)
            } else {
                state.pending_appends.remove(&terminal_id);
                state.tracker.discard_emission(emission);
                Err(error.message().to_string())
            }
        }
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as u64)
        .unwrap_or_default()
}

/// Pick the newest revision when the catalog and screen reads overlap. The
/// daemon contract makes both values monotonic, but either field can be
/// unavailable on an older host.
fn merged_stream_revision(catalog: Option<u64>, screen: Option<u64>) -> Option<u64> {
    match (catalog, screen) {
        (Some(catalog), Some(screen)) => Some(catalog.max(screen)),
        (Some(revision), None) | (None, Some(revision)) => Some(revision),
        (None, None) => None,
    }
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

    #[test]
    fn configured_session_selector_does_not_fall_back_to_current() {
        let id = SessionId::parse("session_00000000000000000000000000000001").unwrap();
        assert_eq!(configured_session_selector(id.as_str()).unwrap(), Selector::id(id));
        assert_eq!(configured_session_selector("secondary").unwrap(), Selector::name("secondary"));
        assert!(configured_session_selector("   ").is_err());
    }

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
            acquisition_started_at: None,
        }
    }

    fn cached_with_acquisition_start(
        checked_at: Instant,
        acquisition_started_at: Instant,
    ) -> CachedProcessInfo {
        let mut entry = cached(checked_at, true, Some(7));
        entry.acquisition_started_at = Some(acquisition_started_at);
        entry
    }

    fn cached_group(
        checked_at: Instant,
        identified: bool,
        stream_revision: Option<u64>,
    ) -> CachedProcessGroup {
        CachedProcessGroup {
            pid: 42,
            foreground_name: Some("shell".into()),
            checked_at,
            stream_revision,
            job: process_discovery::ForegroundJob { process_group_id: 42, processes: Vec::new() },
            authoritative: true,
            identified,
            acquisition_started_at: None,
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
    fn missing_output_revision_keeps_process_probe_bounded() {
        let start = Instant::now();
        let entry = cached(start, true, None);
        assert!(!process_info_refresh_due(
            &entry,
            None,
            start + PROCESS_INFO_RECHECK_ON_OUTPUT - Duration::from_millis(1),
        ));
        assert!(process_info_refresh_due(&entry, None, start + PROCESS_INFO_RECHECK_ON_OUTPUT,));
    }

    #[test]
    fn newly_identified_processes_use_adaptive_acquisition_rechecks() {
        let start = Instant::now();
        let entry = cached_with_acquisition_start(start, start);
        assert!(!process_info_refresh_due(
            &entry,
            Some(7),
            start + PROCESS_ACQUISITION_FAST_RECHECK - Duration::from_millis(1),
        ));
        assert!(process_info_refresh_due(
            &entry,
            Some(7),
            start + PROCESS_ACQUISITION_FAST_RECHECK,
        ));
        let slow_check =
            cached_with_acquisition_start(start + PROCESS_ACQUISITION_FAST_WINDOW, start);
        assert!(!process_info_refresh_due(
            &slow_check,
            Some(7),
            slow_check.checked_at + PROCESS_ACQUISITION_SLOW_RECHECK - Duration::from_millis(1),
        ));
        assert!(process_info_refresh_due(
            &slow_check,
            Some(7),
            slow_check.checked_at + PROCESS_ACQUISITION_SLOW_RECHECK,
        ));
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
    fn unknown_process_groups_recheck_quickly_for_spawn_detection() {
        let start = Instant::now();
        let entry = cached_group(start, false, Some(7));
        assert!(!process_group_refresh_due(
            &entry,
            Some(8),
            start + PROCESS_GROUP_RECHECK_UNKNOWN - Duration::from_millis(1),
        ));
        assert!(process_group_refresh_due(&entry, Some(8), start + PROCESS_GROUP_RECHECK_UNKNOWN,));
    }

    #[test]
    fn identified_process_groups_recheck_on_output_within_one_second() {
        let start = Instant::now();
        let entry = cached_group(start, true, Some(7));
        assert!(!process_group_refresh_due(
            &entry,
            Some(8),
            start + PROCESS_GROUP_RECHECK_ON_OUTPUT - Duration::from_millis(1),
        ));
        assert!(process_group_refresh_due(
            &entry,
            Some(8),
            start + PROCESS_GROUP_RECHECK_ON_OUTPUT,
        ));
    }

    #[test]
    fn missing_output_revision_keeps_process_group_probe_bounded() {
        let start = Instant::now();
        let entry = cached_group(start, true, None);
        assert!(!process_group_refresh_due(
            &entry,
            None,
            start + PROCESS_GROUP_RECHECK_ON_OUTPUT - Duration::from_millis(1),
        ));
        assert!(process_group_refresh_due(&entry, None, start + PROCESS_GROUP_RECHECK_ON_OUTPUT,));
    }

    #[test]
    fn emission_keys_are_unique_for_one_connection() {
        let first = emission_idempotency_key("17-123456789", 0);
        let second = emission_idempotency_key("17-123456789", 1);
        assert_ne!(first, second);
        assert!(first.len() <= 128);
        assert!(second.len() <= 128);
    }

    #[test]
    fn merged_stream_revision_uses_the_newest_available_host_value() {
        assert_eq!(merged_stream_revision(None, None), None);
        assert_eq!(merged_stream_revision(Some(7), None), Some(7));
        assert_eq!(merged_stream_revision(None, Some(8)), Some(8));
        assert_eq!(merged_stream_revision(Some(7), Some(8)), Some(8));
        assert_eq!(merged_stream_revision(Some(9), Some(8)), Some(9));
    }

    #[test]
    fn terminal_retention_keeps_uncertain_appends_for_replay() {
        let terminal_id = "terminal-1".to_string();
        let mut state = ScannerState::new();
        let now = Instant::now();
        state.tracker.note_foreground_agent_at(&terminal_id, Some("codex"), now);
        let emission =
            state.tracker.record_identity_presence_at(&terminal_id, "codex", now).unwrap();
        state.tracker.commit_emission(&emission);
        state.pending_appends.insert(
            terminal_id.clone(),
            PendingAppend {
                emission: crate::detect::ScreenDetectEmission {
                    terminal_id: terminal_id.clone(),
                    agent: "codex".into(),
                    state: AgentState::Working,
                    matched_rule: None,
                    visible_idle: false,
                    visible_blocker: false,
                    visible_working: true,
                },
                ingress: JournalIngress {
                    producer_id: "plugin".into(),
                    manifest_version: 1,
                    kind: "plugin.agent.state.changed".into(),
                    schema_version: 1,
                    occurred_at_ms: None,
                    subjects: Vec::new(),
                    sensitivity: None,
                    payload: json!({}),
                    causation_id: None,
                    correlation_id: None,
                },
                idempotency_key: "key".into(),
                attempts: 1,
                retry_not_before: Instant::now(),
            },
        );

        state.retain_terminals(&HashSet::new());

        assert!(state.pending_appends.contains_key(&terminal_id));
        assert!(state.tracker.has_live_emission(&terminal_id));
    }
}
