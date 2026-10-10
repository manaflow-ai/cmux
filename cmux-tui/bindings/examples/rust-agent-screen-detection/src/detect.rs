//! Screen-derived agent lifecycle detection.
//!
//! Detection semantics derived from herdr (https://github.com/herdrdev/herdr),
//! Apache-2.0, commit `7b675f42af35508eab66ac42fe1598628597a893`, especially
//! `src/detect/mod.rs` and `src/pane/agent_detection.rs`, modified by
//! manaflow. First-acquisition OSC retention follows herdr commit
//! `82e6a80eb3ae39fb3d3ebd4d1fed19389767e605` (`src/pane.rs`), adapted here
//! as a local metadata fence because the generic host API does not let a
//! plugin clear terminal OSC state.
//!
//! The plugin watches every PTY's output stream; when a terminal goes quiet
//! (debounced), the foreground process name selects a herdr-derived manifest
//! and the terminal tail is evaluated against it. State transitions, never
//! per-scan states, append namespaced `agent.*` journal events, so the
//! journal-derived roster covers agents that expose no hooks. The engine port
//! lives in [`manifest`]; this module owns pure edge-trigger bookkeeping.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use crate::manifest::{Detection, ScreenState};

/// States emitted by the detector. They are serialized as the generic cmux
/// agent state strings at the journal boundary.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AgentState {
    Working,
    Blocked,
    Idle,
    Done,
}

impl AgentState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Working => "working",
            Self::Blocked => "blocked",
            Self::Idle => "idle",
            Self::Done => "done",
        }
    }
}

/// Output must be quiet this long before the screen is evaluated, so
/// mid-redraw frames are rarely matched.
pub(crate) const QUIESCENCE_DEBOUNCE_MS: u64 = 300;

/// A screen that never goes quiet (agent spinners animate every ~100ms,
/// so a working codex never quiesces) is still evaluated at this pace.
/// Without it, quiescence gating starves detection during the exact
/// phase it exists to report.
pub(crate) const MAX_EVAL_INTERVAL_MS: u64 = 1_000;

/// Recent PTY output is a working signal for a screen source. It upgrades an
/// otherwise idle screen and expires through one deterministic re-evaluation.
pub(crate) const WORKING_ACTIVITY_WINDOW_MS: u64 = 1_500;

/// Herdr confirms a plain idle screen several times before replacing a
/// working state. This avoids a single redraw frame making a live turn look
/// complete.
pub(crate) const PENDING_IDLE_RECHECK_MS: u64 = 100;
pub(crate) const PENDING_IDLE_CONFIRMATIONS: u8 = 3;
pub(crate) const PENDING_IDLE_CAP_MS: u64 = 700;

/// A visible blocker is still live evidence even when its text does not
/// change. Refreshing it keeps roster recency useful for long prompts.
pub(crate) const STABLE_BLOCKER_REFRESH_MS: u64 = 800;

/// Do not classify the first screen after a process identity edge. A shell
/// can leave its old prompt in the viewport while the agent is starting. The
/// process identity gives immediate presence; this grace window gives the
/// agent time to draw its own screen before screen rules can assert state.
pub(crate) const AGENT_STARTUP_GRACE_MS: u64 = 3_000;

/// Process inspection can briefly return no foreground process while a PTY
/// changes groups or a platform permission check races the scan. Keep the
/// last agent through the same six consecutive misses used by herdr before
/// treating the identity as an exit.
pub(crate) const AGENT_MISS_CONFIRMATION_ATTEMPTS: u8 = 6;

#[derive(Debug, Clone, Default)]
struct PendingIdle {
    started_at: Option<Instant>,
    confirmations: u8,
}

/// The part of a tracked terminal that an emission mutates. The scanner
/// records this snapshot before it appends to the journal. If admission fails,
/// the snapshot is restored so the next scan can publish the same edge.
#[derive(Debug, Clone)]
struct TrackerSnapshot {
    emitted: Option<(String, AgentState)>,
    identity_presence_needed: bool,
    visible_idle: bool,
    visible_blocker: bool,
    visible_working: bool,
    last_visible_blocker_refresh: Option<Instant>,
    pending_idle: PendingIdle,
}

impl TrackerSnapshot {
    fn capture(entry: &TrackedTerminal) -> Self {
        Self {
            emitted: entry.emitted.clone(),
            identity_presence_needed: entry.identity_presence_needed,
            visible_idle: entry.visible_idle,
            visible_blocker: entry.visible_blocker,
            visible_working: entry.visible_working,
            last_visible_blocker_refresh: entry.last_visible_blocker_refresh,
            pending_idle: entry.pending_idle.clone(),
        }
    }
}

#[derive(Debug, Clone)]
struct PendingEmission {
    emission: ScreenDetectEmission,
    before: TrackerSnapshot,
    after: TrackerSnapshot,
}

impl PendingEmission {
    fn arm(entry: &mut TrackedTerminal, before: TrackerSnapshot, emission: ScreenDetectEmission) {
        let after = TrackerSnapshot::capture(entry);
        entry.pending_emission = Some(Self { emission, before, after });
    }

    fn matches(&self, emission: &ScreenDetectEmission) -> bool {
        self.emission == *emission
    }
}

impl TrackerSnapshot {
    fn restore(self, entry: &mut TrackedTerminal) {
        entry.emitted = self.emitted;
        entry.identity_presence_needed = self.identity_presence_needed;
        entry.visible_idle = self.visible_idle;
        entry.visible_blocker = self.visible_blocker;
        entry.visible_working = self.visible_working;
        entry.last_visible_blocker_refresh = self.last_visible_blocker_refresh;
        entry.pending_idle = self.pending_idle;
    }
}

impl PendingIdle {
    fn clear(&mut self) {
        self.started_at = None;
        self.confirmations = 0;
    }

    fn active(&self) -> bool {
        self.started_at.is_some()
    }

    fn should_hold(&mut self, now: Instant) -> bool {
        let Some(started_at) = self.started_at else {
            self.started_at = Some(now);
            self.confirmations = 0;
            return true;
        };
        if now.duration_since(started_at).as_millis() as u64 >= PENDING_IDLE_CAP_MS {
            self.clear();
            return false;
        }
        self.confirmations = self.confirmations.saturating_add(1);
        if self.confirmations >= PENDING_IDLE_CONFIRMATIONS {
            self.clear();
            false
        } else {
            true
        }
    }
}

/// Whether retained OSC metadata may be used without a new PTY revision.
/// Herdr clears the host's OSC fields when leaving an identified agent. The
/// cmux host API is deliberately generic and cannot perform that reset for a
/// plugin, so the plugin models the same boundary locally.
#[derive(Debug, Clone, Copy, Default)]
enum OscMetadataState {
    /// No agent has been identified on this terminal yet.
    #[default]
    NeverIdentified,
    /// The first recognized agent may have emitted its title or progress
    /// before process inspection caught up, so retained evidence stays usable.
    FirstAgent,
    /// A replacement or confirmed exit occurred. A revision is optional for
    /// older hosts. A known fence fails closed when the current host omits its
    /// revision, because the plugin cannot prove that retained OSC data is new.
    Fenced { identity_revision: Option<u64> },
}

impl OscMetadataState {
    fn is_fresh(self, stream_revision: Option<u64>) -> bool {
        match self {
            Self::NeverIdentified | Self::FirstAgent => true,
            // Old hosts do not expose a revision. Preserve their historical
            // compatibility behavior because there is no generation anchor
            // to compare against.
            Self::Fenced { identity_revision: None } => true,
            // Once a host has supplied an anchor, missing metadata is not
            // evidence that the retained OSC fields belong to a new process.
            Self::Fenced { identity_revision: Some(identity_revision) } => {
                stream_revision.is_some_and(|current| current > identity_revision)
            }
        }
    }

    fn fence(&mut self, stream_revision: Option<u64>) {
        *self = Self::Fenced { identity_revision: stream_revision };
    }
}

/// One state transition the scanner must journal.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScreenDetectEmission {
    pub terminal_id: String,
    /// Manifest id of the detected agent (`codex`, `claude`, ...).
    pub agent: String,
    pub state: AgentState,
    pub matched_rule: Option<String>,
    pub visible_idle: bool,
    pub visible_blocker: bool,
    pub visible_working: bool,
}

#[derive(Debug, Default)]
struct TrackedTerminal {
    /// Last observed output-stream revision.
    revision: u64,
    /// When that revision was first observed (debounce anchor).
    quiet_since: Option<Instant>,
    /// Revision already evaluated; skip re-evaluating identical screens.
    evaluated_revision: Option<u64>,
    /// When the screen was last evaluated (the max-interval pacer anchor).
    last_evaluated_at: Option<Instant>,
    /// When output last advanced the revision. The first observation only
    /// anchors the tracker and is not treated as fresh activity.
    last_output_at: Option<Instant>,
    /// The last evaluation used output activity to upgrade idle to working.
    /// This creates one expiry re-evaluation even when the screen is unchanged.
    evaluated_with_activity: bool,
    /// Agent the foreground process matched on the previous scan; identity
    /// edges trigger immediate evaluation, before any quiescence.
    foreground_agent: Option<String>,
    /// Foreground process group for the matched agent. A replacement process
    /// can keep the same executable name, so a group change is also an
    /// identity edge when both probes provide a group id.
    foreground_process_group: Option<u32>,
    /// Deadline for the stale-screen guard after an agent identity edge.
    startup_grace_until: Option<Instant>,
    /// First acquisition accepts retained evidence. A replacement or confirmed
    /// exit changes this to `Fenced`, so a later process cannot inherit the
    /// prior process's metadata.
    osc_metadata_state: OscMetadataState,
    /// Consecutive process probes that did not identify an agent. A positive
    /// probe resets this counter, so a transient inspection miss cannot close
    /// a live row.
    foreground_misses: u8,
    /// Last (agent, state) journaled; emissions are edges over this.
    emitted: Option<(String, AgentState)>,
    /// Visibility evidence from the last emitted state. It drives stable
    /// blocker refresh without treating every evaluation as a transition.
    visible_idle: bool,
    visible_blocker: bool,
    visible_working: bool,
    last_visible_blocker_refresh: Option<Instant>,
    pending_idle: PendingIdle,
    /// The pre-emission state until the scanner confirms journal admission.
    /// Only one emission is in flight because appends are synchronous.
    pending_emission: Option<PendingEmission>,
    /// A process identity edge remains unsatisfied until its presence event
    /// is admitted. This is separate from the last screen state because an
    /// agent can replace another agent while both report `idle`.
    identity_presence_needed: bool,
    /// A failed transport keeps the exact edge available for idempotent
    /// replay. The scanner retries this before evaluating a newer screen.
    retry_emission: Option<PendingEmission>,
}

/// Pure edge-trigger state for the scanner. All timing is passed in, so
/// tests drive it deterministically.
#[derive(Debug, Default)]
pub struct ScreenDetectTracker {
    terminals: HashMap<String, TrackedTerminal>,
}

impl ScreenDetectTracker {
    /// Record the terminal's current output revision. Returns `true` when
    /// the screen changed since the last evaluation and either output has
    /// been quiet for the debounce window or the max-interval pacer is due
    /// (a never-quiet spinner screen still evaluates at 1Hz; quiescence
    /// alone starves detection during the exact phase it must report). A
    /// `true` return arms the pacer: the caller always evaluates then.
    pub fn observe_revision(&mut self, terminal_id: &str, revision: u64, now: Instant) -> bool {
        let entry = self.terminals.entry(terminal_id.to_string()).or_default();
        if entry.quiet_since.is_none() {
            entry.revision = revision;
            entry.quiet_since = Some(now);
        } else if entry.revision != revision {
            entry.revision = revision;
            entry.quiet_since = Some(now);
            entry.last_output_at = Some(now);
        }
        let output_active = entry.last_output_at.is_some_and(|at| {
            now.duration_since(at).as_millis() as u64 <= WORKING_ACTIVITY_WINDOW_MS
        });
        let activity_expired = entry.evaluated_with_activity && !output_active;
        let pending_idle_due = entry.pending_idle.active()
            && entry.last_evaluated_at.is_none_or(|at| {
                now.duration_since(at).as_millis() as u64 >= PENDING_IDLE_RECHECK_MS
            });
        let stable_blocker_due = entry.visible_blocker
            && entry.last_visible_blocker_refresh.is_none_or(|at| {
                now.duration_since(at).as_millis() as u64 >= STABLE_BLOCKER_REFRESH_MS
            });
        if entry.evaluated_revision == Some(entry.revision)
            && !activity_expired
            && !pending_idle_due
            && !stable_blocker_due
        {
            return false;
        }
        let quiet_since = entry.quiet_since.expect("anchored above");
        let quiesced = now.duration_since(quiet_since).as_millis() as u64 >= QUIESCENCE_DEBOUNCE_MS;
        let overdue = entry.last_evaluated_at.is_none_or(|evaluated_at| {
            now.duration_since(evaluated_at).as_millis() as u64 >= MAX_EVAL_INTERVAL_MS
        });
        if quiesced || overdue || activity_expired || pending_idle_due || stable_blocker_due {
            entry.last_evaluated_at = Some(now);
            entry.evaluated_with_activity = false;
            return true;
        }
        false
    }

    /// One-shot work owed by a concrete observation. A stable terminal has
    /// no deadline, including a visible blocker: journal recency is event
    /// time, not a heartbeat. Process uncertainty is a bounded confirmation
    /// sequence armed by output, never a periodic process scan.
    pub(crate) fn next_deadline(&self, terminal_id: &str, now: Instant) -> Option<Instant> {
        let entry = self.terminals.get(terminal_id)?;
        entry.foreground_agent.as_ref()?;
        if let Some(deadline) = entry.startup_grace_until {
            return Some(deadline.max(now));
        }
        let mut deadlines = Vec::new();
        if entry.foreground_misses > 0 && entry.foreground_misses < AGENT_MISS_CONFIRMATION_ATTEMPTS
        {
            deadlines.push(now + Duration::from_millis(PENDING_IDLE_RECHECK_MS));
        }
        if entry.evaluated_revision != Some(entry.revision)
            && let Some(quiet) = entry.quiet_since
        {
            deadlines.push(quiet + Duration::from_millis(QUIESCENCE_DEBOUNCE_MS));
        }
        if entry.evaluated_with_activity
            && let Some(output) = entry.last_output_at
        {
            deadlines.push(output + Duration::from_millis(WORKING_ACTIVITY_WINDOW_MS + 1));
        }
        if entry.pending_idle.active() {
            deadlines.push(now + Duration::from_millis(PENDING_IDLE_RECHECK_MS));
        }
        deadlines.into_iter().min().map(|deadline| deadline.max(now))
    }

    /// Mark that the last screen evaluation used flowing PTY output to
    /// upgrade an idle state. The tracker then owes an expiry evaluation.
    pub(crate) fn note_activity_upgrade(&mut self, terminal_id: &str) {
        if let Some(entry) = self.terminals.get_mut(terminal_id) {
            entry.evaluated_with_activity = true;
        }
    }

    /// True while PTY output has advanced within the activity window.
    pub(crate) fn output_active(&self, terminal_id: &str, now: Instant) -> bool {
        self.terminals.get(terminal_id).and_then(|entry| entry.last_output_at).is_some_and(|at| {
            now.duration_since(at).as_millis() as u64 <= WORKING_ACTIVITY_WINDOW_MS
        })
    }

    /// Return whether generic OSC metadata may be attributed to the current
    /// foreground process. Hosts without a stream revision remain supported,
    /// but the plugin cannot prove that their retained metadata is fresh. A
    /// terminal with a known fence fails closed while its current revision is
    /// missing.
    pub(crate) fn metadata_is_fresh(
        &self,
        terminal_id: &str,
        stream_revision: Option<u64>,
    ) -> bool {
        let Some(entry) = self.terminals.get(terminal_id) else {
            return true;
        };
        // Match herdr's first-acquisition rule. A newly recognized agent may
        // have emitted its OSC title or progress before the process probe
        // caught up, so do not discard that evidence on the first edge.
        entry.osc_metadata_state.is_fresh(stream_revision)
    }

    /// True when this terminal previously journaled a screen-derived state
    /// that has not been closed out by an exit emission.
    pub fn has_live_emission(&self, terminal_id: &str) -> bool {
        self.terminals.get(terminal_id).is_some_and(|entry| entry.emitted.is_some())
    }

    /// Return whether the process identity still needs a durable presence
    /// edge. This stays true after a failed append, including when the
    /// foreground agent changed while an older agent row was live.
    pub(crate) fn needs_identity_presence(&self, terminal_id: &str, agent: &str) -> bool {
        self.terminals.get(terminal_id).is_none_or(|entry| {
            entry.identity_presence_needed
                || entry.emitted.as_ref().is_none_or(|(current_agent, _)| current_agent != agent)
        })
    }

    /// Record which agent the foreground process currently matches. Returns
    /// `true` on an identity edge (spawn, swap, or exit), which evaluates
    /// the screen immediately: presence comes from the process, so the row
    /// appears the moment `codex` starts, not after its first quiet screen.
    pub fn note_foreground_agent(&mut self, terminal_id: &str, agent: Option<&str>) -> bool {
        self.note_foreground_agent_at(terminal_id, agent, Instant::now())
    }

    /// Record a foreground identity edge with deterministic timing. A newly
    /// identified process starts a grace window during which the scanner must
    /// not interpret the previous shell or agent viewport as its state.
    pub fn note_foreground_agent_at(
        &mut self,
        terminal_id: &str,
        agent: Option<&str>,
        now: Instant,
    ) -> bool {
        self.note_foreground_job_at(terminal_id, agent, None, now)
    }

    /// Record a foreground identity and, when available, its process group.
    /// A same-name process replacement is an edge only when both observations
    /// carry a group id. Missing group data must not manufacture a restart.
    pub fn note_foreground_job_at(
        &mut self,
        terminal_id: &str,
        agent: Option<&str>,
        process_group_id: Option<u32>,
        now: Instant,
    ) -> bool {
        self.note_foreground_job_at_with_revision(terminal_id, agent, process_group_id, None, now)
    }

    /// Record a foreground identity edge and the host stream revision seen at
    /// that edge. On replacement edges, the revision lets the userland
    /// detector reject OSC title or progress retained from the previous
    /// process without adding agent semantics to the host metadata API. The
    /// first acquisition keeps evidence that may have arrived before probing.
    pub(crate) fn note_foreground_job_at_with_revision(
        &mut self,
        terminal_id: &str,
        agent: Option<&str>,
        process_group_id: Option<u32>,
        stream_revision: Option<u64>,
        now: Instant,
    ) -> bool {
        let entry = self.terminals.entry(terminal_id.to_string()).or_default();
        match agent {
            Some(agent) => {
                // A successful probe confirms the existing identity and
                // cancels any transient-miss window.
                entry.foreground_misses = 0;
                let agent_changed = entry.foreground_agent.as_deref() != Some(agent);
                let process_group_changed = matches!(
                    (entry.foreground_process_group, process_group_id),
                    (Some(previous), Some(current)) if previous != current
                );
                if !agent_changed && !process_group_changed {
                    // A platform can expose the group only after the first
                    // probe. Enrich the identity without restarting grace.
                    if process_group_id.is_some() {
                        entry.foreground_process_group = process_group_id;
                    }
                    // Likewise, an older daemon can begin exposing the
                    // revision after the identity was established. Anchor it
                    // once, so retained metadata is fenced as soon as the
                    // host provides the evidence needed to fence it.
                    if let OscMetadataState::Fenced { identity_revision } =
                        &mut entry.osc_metadata_state
                        && identity_revision.is_none()
                    {
                        *identity_revision = stream_revision;
                    }
                    return false;
                }
                // A first acquisition keeps OSC evidence already emitted by
                // the process. Once any agent was identified, a replacement
                // must wait for a newer stream revision, including after a
                // confirmed exit where the host could not clear its state.
                let first_acquisition = entry.foreground_agent.is_none()
                    && entry.emitted.is_none()
                    && matches!(entry.osc_metadata_state, OscMetadataState::NeverIdentified);
                if first_acquisition {
                    entry.osc_metadata_state = OscMetadataState::FirstAgent;
                } else {
                    entry.osc_metadata_state.fence(stream_revision);
                }
            }
            None => {
                let Some(_) = entry.foreground_agent else {
                    entry.foreground_misses = 0;
                    return false;
                };
                entry.foreground_misses = entry.foreground_misses.saturating_add(1);
                if entry.foreground_misses < AGENT_MISS_CONFIRMATION_ATTEMPTS {
                    return false;
                }
                // The identity is actually gone. Clear the counter before
                // publishing the edge so a later agent starts cleanly.
                entry.foreground_misses = 0;
                // The host cannot clear its retained OSC fields on this edge.
                // Preserve a fence so the next acquisition cannot inherit the
                // first agent's metadata.
                entry.osc_metadata_state.fence(stream_revision);
            }
        }
        entry.foreground_agent = agent.map(str::to_string);
        entry.foreground_process_group = agent.and(process_group_id);
        entry.identity_presence_needed = agent.is_some();
        entry.startup_grace_until =
            agent.map(|_| now + Duration::from_millis(AGENT_STARTUP_GRACE_MS));
        // A process identity edge invalidates the prior screen evaluation.
        // If the first read for the new process fails, the next scan must
        // retry even when the PTY revision did not change.
        entry.evaluated_revision = None;
        // Do not carry shell or previous-agent output activity across the
        // identity edge. New PTY output during the grace window will re-arm
        // this signal through observe_revision.
        entry.last_output_at = None;
        entry.evaluated_with_activity = false;
        entry.pending_idle.clear();
        true
    }

    /// The last identity that survived the miss-confirmation window. The
    /// scanner uses this to distinguish a transient process-query miss from
    /// a confirmed agent exit without exposing process policy to core.
    pub(crate) fn foreground_agent(&self, terminal_id: &str) -> Option<&str> {
        self.terminals.get(terminal_id).and_then(|entry| entry.foreground_agent.as_deref())
    }

    /// Returns `true` while the stale-screen guard is active.
    pub(crate) fn startup_grace_active(&self, terminal_id: &str, now: Instant) -> bool {
        self.terminals
            .get(terminal_id)
            .and_then(|entry| entry.startup_grace_until)
            .is_some_and(|until| now < until)
    }

    /// End an expired startup grace window and force one screen evaluation.
    /// The return value is edge-triggered, so a steady process does not cause
    /// repeated forced reads after the deadline.
    pub(crate) fn finish_startup_grace(&mut self, terminal_id: &str, now: Instant) -> bool {
        let Some(entry) = self.terminals.get_mut(terminal_id) else {
            return false;
        };
        let Some(until) = entry.startup_grace_until else {
            return false;
        };
        if now < until {
            return false;
        }
        entry.startup_grace_until = None;
        entry.evaluated_revision = None;
        entry.pending_idle.clear();
        true
    }

    /// Emit presence from process identity without reading the viewport.
    /// This keeps the roster responsive while the startup grace window blocks
    /// stale screen classification.
    pub(crate) fn record_identity_presence_at(
        &mut self,
        terminal_id: &str,
        agent: &str,
        _now: Instant,
    ) -> Option<ScreenDetectEmission> {
        let entry = self.terminals.entry(terminal_id.to_string()).or_default();
        entry.pending_emission = None;
        // A direct tracker caller may advance state without the scanner. In
        // that case an old retry is superseded; the scanner retries first.
        entry.retry_emission = None;
        let before = TrackerSnapshot::capture(entry);
        entry.pending_idle.clear();
        entry.visible_idle = false;
        entry.visible_blocker = false;
        entry.visible_working = false;
        entry.last_visible_blocker_refresh = None;
        let next = (agent.to_string(), AgentState::Idle);
        if entry.emitted.as_ref() == Some(&next) && !entry.identity_presence_needed {
            entry.identity_presence_needed = false;
            return None;
        }
        entry.emitted = Some(next);
        let emission = ScreenDetectEmission {
            terminal_id: terminal_id.to_string(),
            agent: agent.to_string(),
            state: AgentState::Idle,
            matched_rule: None,
            visible_idle: false,
            visible_blocker: false,
            visible_working: false,
        };
        entry.identity_presence_needed = false;
        PendingEmission::arm(entry, before, emission.clone());
        Some(emission)
    }

    /// Fold one evaluated detection. `None` detection means the foreground
    /// process is not a supported agent (or is gone): a live screen-derived
    /// entry is closed with a session-ended-equivalent `Done` emission.
    pub fn record_detection(
        &mut self,
        terminal_id: &str,
        detection: Option<(&str, Detection)>,
    ) -> Option<ScreenDetectEmission> {
        self.record_detection_at(terminal_id, detection, Instant::now(), false, false)
    }

    /// Record one evaluated screen with explicit timing and lifecycle edges.
    /// The scanner uses this method; the timing-free wrapper above keeps the
    /// pure state API convenient for callers that only need edge folding.
    pub fn record_detection_at(
        &mut self,
        terminal_id: &str,
        detection: Option<(&str, Detection)>,
        now: Instant,
        identity_edge: bool,
        process_exited: bool,
    ) -> Option<ScreenDetectEmission> {
        self.record_detection_at_with_revision(
            terminal_id,
            detection,
            now,
            identity_edge,
            process_exited,
            None,
        )
    }

    /// Record one evaluated screen and, when the host supplied one, the
    /// daemon's output revision at the lifecycle edge. The local `revision`
    /// field is only a scheduling key and must never be used as an OSC fence.
    pub(crate) fn record_detection_at_with_revision(
        &mut self,
        terminal_id: &str,
        detection: Option<(&str, Detection)>,
        now: Instant,
        identity_edge: bool,
        process_exited: bool,
        stream_revision: Option<u64>,
    ) -> Option<ScreenDetectEmission> {
        let entry = self.terminals.entry(terminal_id.to_string()).or_default();
        entry.pending_emission = None;
        // See the identity-presence path above. A scanner retry is handled
        // before this method is called, so a fresh direct fold can replace it.
        entry.retry_emission = None;
        let before = TrackerSnapshot::capture(entry);
        if process_exited {
            // A terminal exit is authoritative. Do not retain the identity
            // or its startup grace when the PTY has gone away.
            if entry.foreground_agent.is_some() {
                // `entry.revision` may be a local screen hash on older hosts.
                // Only a host-provided stream revision can establish the
                // post-exit generation boundary.
                entry.osc_metadata_state.fence(stream_revision);
            }
            entry.foreground_agent = None;
            entry.foreground_process_group = None;
            entry.foreground_misses = 0;
            entry.startup_grace_until = None;
            entry.identity_presence_needed = false;
        }
        entry.evaluated_revision = Some(entry.revision);
        let Some((agent, detection)) = detection else {
            entry.pending_idle.clear();
            entry.visible_idle = false;
            entry.visible_blocker = false;
            entry.visible_working = false;
            entry.last_visible_blocker_refresh = None;
            let (agent, _) = entry.emitted.take()?;
            let emission = ScreenDetectEmission {
                terminal_id: terminal_id.to_string(),
                agent,
                state: AgentState::Done,
                matched_rule: None,
                visible_idle: false,
                visible_blocker: false,
                visible_working: false,
            };
            PendingEmission::arm(entry, before, emission.clone());
            return Some(emission);
        };
        let asserted = if detection.skip_state_update {
            // Agent-owned viewer (transcript scroll etc.): keep prior state.
            None
        } else {
            match detection.state {
                ScreenState::Working => Some(AgentState::Working),
                ScreenState::Blocked => Some(AgentState::Blocked),
                ScreenState::Idle => Some(AgentState::Idle),
                // A matched unknown-state rule asserts nothing.
                ScreenState::Unknown => None,
            }
        };
        let state = match (asserted, &entry.emitted) {
            (Some(state), _) => state,
            // The screen asserts nothing but the process IS the agent:
            // presence must not wait for a stable screen, so the first
            // emission for a terminal is idle until a later scan refines.
            (None, None) => AgentState::Idle,
            // A live emission keeps its prior state through viewer screens.
            (None, Some(_)) => return None,
        };
        let visible_idle = detection.visible_idle && state == AgentState::Idle;
        let visible_blocker = detection.visible_blocker && state == AgentState::Blocked;
        let visible_working = detection.visible_working && state == AgentState::Working;
        let previous_state = entry.emitted.as_ref().map(|(_, state)| *state);
        let plain_working_to_idle = previous_state == Some(AgentState::Working)
            && state == AgentState::Idle
            && !visible_idle
            && !visible_blocker
            && !identity_edge
            && !process_exited;
        if plain_working_to_idle {
            if entry.pending_idle.should_hold(now) {
                return None;
            }
        } else {
            entry.pending_idle.clear();
        }
        let next = (agent.to_string(), state);
        let stable_blocker_refresh = next.1 == AgentState::Blocked
            && visible_blocker
            && entry.visible_blocker
            && entry.last_visible_blocker_refresh.is_none_or(|at| {
                now.duration_since(at).as_millis() as u64 >= STABLE_BLOCKER_REFRESH_MS
            });
        if entry.emitted.as_ref() == Some(&next) && !stable_blocker_refresh {
            return None;
        }
        entry.emitted = Some(next);
        entry.visible_idle = visible_idle;
        entry.visible_blocker = visible_blocker;
        entry.visible_working = visible_working;
        entry.last_visible_blocker_refresh = visible_blocker.then_some(now);
        let emission = ScreenDetectEmission {
            terminal_id: terminal_id.to_string(),
            agent: agent.to_string(),
            state,
            matched_rule: detection.matched_rule,
            visible_idle,
            visible_blocker,
            visible_working,
        };
        PendingEmission::arm(entry, before, emission.clone());
        Some(emission)
    }

    /// Mark an emission durable. The tracker keeps no pending transaction
    /// after a successful journal append.
    pub(crate) fn commit_emission(&mut self, emission: &ScreenDetectEmission) {
        let Some(entry) = self.terminals.get_mut(&emission.terminal_id) else { return };
        if let Some(pending) = entry.pending_emission.take() {
            if pending.matches(emission) {
                // The initial append already left the tracker in this state.
                // The restore also makes this method correct for a replayed
                // retry.
                pending.after.restore(entry);
                return;
            }
            // A late callback for another edge must not consume the current
            // transaction.
            entry.pending_emission = Some(pending);
        }
        if let Some(retry) = entry.retry_emission.take() {
            if retry.matches(emission) {
                retry.after.restore(entry);
                return;
            }
            // A late callback for another edge must not consume the retry.
            entry.retry_emission = Some(retry);
        }
    }

    /// Undo an edge when journal admission fails. The next scan must be able
    /// to emit the same transition again instead of treating it as delivered.
    pub(crate) fn rollback_emission(&mut self, emission: &ScreenDetectEmission) {
        let Some(entry) = self.terminals.get_mut(&emission.terminal_id) else { return };
        if let Some(pending) = entry.pending_emission.take() {
            if pending.matches(emission) {
                pending.before.clone().restore(entry);
                entry.retry_emission = Some(pending);
                // Force a fresh evaluation even when the PTY revision did not
                // move. The retry remains pending until its exact envelope
                // is accepted or explicitly discarded.
                entry.evaluated_revision = None;
                return;
            }
            entry.pending_emission = Some(pending);
        }
        if entry.retry_emission.as_ref().is_some_and(|pending| pending.matches(emission)) {
            entry.evaluated_revision = None;
            return;
        }
        // Keep the retry safe if a caller supplies an emission created by an
        // older tracker that did not retain a snapshot.
        entry.evaluated_revision = None;
    }

    /// Drop an emission after a definite admission failure. Uncertain
    /// transport failures use `rollback_emission` and retain the retry.
    pub(crate) fn discard_emission(&mut self, emission: &ScreenDetectEmission) {
        let Some(entry) = self.terminals.get_mut(&emission.terminal_id) else { return };
        if entry.pending_emission.as_ref().is_some_and(|pending| pending.matches(emission)) {
            entry.pending_emission = None;
        }
        if entry.retry_emission.as_ref().is_some_and(|pending| pending.matches(emission)) {
            entry.retry_emission = None;
        }
    }

    /// Drop terminals that left the session. Closed terminals are retired
    /// from the roster by the terminal lifecycle, not by an exit emission.
    pub fn retain_terminals(&mut self, live: impl Fn(&str) -> bool) {
        self.terminals.retain(|terminal_id, _| live(terminal_id));
    }
}
