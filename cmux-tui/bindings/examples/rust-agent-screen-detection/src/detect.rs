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
    /// blocker refresh without treating every scanner tick as a transition.
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::{HashSet, hash_map::DefaultHasher};
    use std::hash::BuildHasher;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::Duration;

    #[derive(Clone)]
    struct CountingBuildHasher {
        builds: Arc<AtomicUsize>,
    }

    impl BuildHasher for CountingBuildHasher {
        type Hasher = DefaultHasher;

        fn build_hasher(&self) -> Self::Hasher {
            self.builds.fetch_add(1, Ordering::Relaxed);
            DefaultHasher::new()
        }
    }

    fn detection(state: ScreenState) -> Detection {
        Detection {
            state,
            skip_state_update: false,
            matched_rule: Some("rule".into()),
            visible_idle: false,
            visible_blocker: false,
            visible_working: false,
        }
    }

    #[test]
    fn screen_detect_tracker_debounces_quiescence_per_revision() {
        let mut tracker = ScreenDetectTracker::default();
        let t0 = Instant::now();
        let at = |milliseconds: u64| t0 + Duration::from_millis(milliseconds);

        // A never-evaluated terminal evaluates on first sight.
        assert!(tracker.observe_revision("term_a", 1, t0));
        tracker.record_detection("term_a", Some(("codex", detection(ScreenState::Idle))));
        // An unchanged screen never re-evaluates.
        assert!(!tracker.observe_revision("term_a", 1, at(400)));

        // New output re-arms the debounce; inside the window with a recent
        // evaluation nothing fires.
        assert!(!tracker.observe_revision("term_a", 2, at(500)));
        assert!(!tracker.observe_revision("term_a", 2, at(700)));
        // Quiet long enough: evaluate exactly once per revision.
        assert!(tracker.observe_revision("term_a", 2, at(900)));
        tracker.record_detection("term_a", Some(("codex", detection(ScreenState::Idle))));
        assert!(!tracker.observe_revision("term_a", 2, at(1_100)));
    }

    #[test]
    fn screen_detect_activity_expires_with_one_recheck() {
        let mut tracker = ScreenDetectTracker::default();
        let t0 = Instant::now();
        let at = |milliseconds: u64| t0 + Duration::from_millis(milliseconds);

        assert!(tracker.observe_revision("term_a", 1, t0));
        tracker.record_detection("term_a", Some(("codex", detection(ScreenState::Idle))));
        assert!(!tracker.observe_revision("term_a", 2, at(400)));
        assert!(tracker.observe_revision("term_a", 2, at(800)));
        assert!(tracker.output_active("term_a", at(800)));
        tracker.record_detection("term_a", Some(("codex", detection(ScreenState::Working))));
        tracker.note_activity_upgrade("term_a");

        assert!(!tracker.observe_revision("term_a", 2, at(1_200)));
        assert!(tracker.observe_revision("term_a", 2, at(2_301)));
        assert!(!tracker.output_active("term_a", at(2_301)));
        tracker.record_detection("term_a", Some(("codex", detection(ScreenState::Idle))));
        assert!(!tracker.observe_revision("term_a", 2, at(2_400)));
    }

    #[test]
    fn screen_detect_tracker_paces_evaluation_of_never_quiet_spinner_screens() {
        let mut tracker = ScreenDetectTracker::default();
        let t0 = Instant::now();
        let at = |milliseconds: u64| t0 + Duration::from_millis(milliseconds);

        assert!(tracker.observe_revision("term_a", 1, t0));
        tracker.record_detection("term_a", Some(("codex", detection(ScreenState::Idle))));

        // A working spinner redraws every ~100ms, so the screen never goes
        // quiet for the debounce window. The pacer still evaluates at 1Hz;
        // without it a working codex would stay idle forever.
        let mut evaluations = 0;
        for tick in 1..=25u64 {
            if tracker.observe_revision("term_a", 1 + tick, at(tick * 100)) {
                evaluations += 1;
                tracker
                    .record_detection("term_a", Some(("codex", detection(ScreenState::Working))));
            }
        }
        assert_eq!(evaluations, 2, "1Hz pacer under 2.5s of continuous output");
        assert!(tracker.has_live_emission("term_a"));
    }

    #[test]
    fn screen_detect_tracker_emits_only_state_edges() {
        let mut tracker = ScreenDetectTracker::default();

        let first =
            tracker.record_detection("term_a", Some(("codex", detection(ScreenState::Working))));
        assert_eq!(
            first,
            Some(ScreenDetectEmission {
                terminal_id: "term_a".into(),
                agent: "codex".into(),
                state: AgentState::Working,
                matched_rule: Some("rule".into()),
                visible_idle: false,
                visible_blocker: false,
                visible_working: false,
            })
        );
        // Same state again: no event (edge-triggered, never per-scan).
        let repeat =
            tracker.record_detection("term_a", Some(("codex", detection(ScreenState::Working))));
        assert_eq!(repeat, None);
        // Transition to blocked emits.
        let blocked =
            tracker.record_detection("term_a", Some(("codex", detection(ScreenState::Blocked))));
        assert_eq!(blocked.map(|emission| emission.state), Some(AgentState::Blocked));
    }

    #[test]
    fn failed_journal_admission_rolls_back_an_edge_for_retry() {
        let mut tracker = ScreenDetectTracker::default();

        let first = tracker
            .record_detection("term_a", Some(("codex", detection(ScreenState::Working))))
            .expect("first edge");
        tracker.commit_emission(&first);

        let blocked = tracker
            .record_detection("term_a", Some(("codex", detection(ScreenState::Blocked))))
            .expect("blocked edge");
        tracker.rollback_emission(&blocked);

        let retry = tracker
            .record_detection("term_a", Some(("codex", detection(ScreenState::Blocked))))
            .expect("a rejected edge must be retried");
        assert_eq!(retry.state, AgentState::Blocked);
        assert_eq!(retry.agent, "codex");
    }

    #[test]
    fn replayed_edge_commits_the_post_state_after_rollback() {
        let mut tracker = ScreenDetectTracker::default();
        let working = tracker
            .record_detection("term_a", Some(("codex", detection(ScreenState::Working))))
            .expect("working edge");
        tracker.commit_emission(&working);

        let blocked = tracker
            .record_detection("term_a", Some(("codex", detection(ScreenState::Blocked))))
            .expect("blocked edge");
        tracker.rollback_emission(&blocked);
        tracker.commit_emission(&blocked);

        assert_eq!(
            tracker.record_detection("term_a", Some(("codex", detection(ScreenState::Blocked)))),
            None,
            "a successful replay must commit the edge exactly once",
        );
    }

    #[test]
    fn committed_edges_ignore_a_late_rollback() {
        let mut tracker = ScreenDetectTracker::default();
        let working = tracker
            .record_detection("term_a", Some(("codex", detection(ScreenState::Working))))
            .expect("working edge");
        tracker.commit_emission(&working);
        tracker.rollback_emission(&working);

        assert_eq!(
            tracker.record_detection("term_a", Some(("codex", detection(ScreenState::Working)))),
            None,
            "a committed edge must not be undone by a late failure callback",
        );
    }

    #[test]
    fn screen_detect_tracker_confirms_plain_idle_before_downgrading_working() {
        let mut tracker = ScreenDetectTracker::default();
        let t0 = Instant::now();
        let at = |milliseconds: u64| t0 + Duration::from_millis(milliseconds);
        tracker.record_detection_at(
            "term_a",
            Some(("codex", detection(ScreenState::Working))),
            t0,
            false,
            false,
        );

        // Three 100 ms rechecks are held. The fourth confirms idle.
        assert!(
            tracker
                .record_detection_at(
                    "term_a",
                    Some(("codex", detection(ScreenState::Idle))),
                    at(0),
                    false,
                    false,
                )
                .is_none()
        );
        assert!(
            tracker
                .record_detection_at(
                    "term_a",
                    Some(("codex", detection(ScreenState::Idle))),
                    at(PENDING_IDLE_RECHECK_MS),
                    false,
                    false,
                )
                .is_none()
        );
        assert!(
            tracker
                .record_detection_at(
                    "term_a",
                    Some(("codex", detection(ScreenState::Idle))),
                    at(PENDING_IDLE_RECHECK_MS * 2),
                    false,
                    false,
                )
                .is_none()
        );
        assert_eq!(
            tracker
                .record_detection_at(
                    "term_a",
                    Some(("codex", detection(ScreenState::Idle))),
                    at(PENDING_IDLE_RECHECK_MS * 3),
                    false,
                    false,
                )
                .map(|emission| emission.state),
            Some(AgentState::Idle)
        );
    }

    #[test]
    fn screen_detect_tracker_refreshes_a_stable_visible_blocker() {
        let mut tracker = ScreenDetectTracker::default();
        let t0 = Instant::now();
        let blocked = Detection {
            state: ScreenState::Blocked,
            skip_state_update: false,
            matched_rule: Some("confirm".into()),
            visible_idle: false,
            visible_blocker: true,
            visible_working: false,
        };
        assert!(
            tracker
                .record_detection_at("term_a", Some(("codex", blocked.clone())), t0, false, false)
                .is_some()
        );
        assert!(
            tracker
                .record_detection_at(
                    "term_a",
                    Some(("codex", blocked.clone())),
                    t0 + Duration::from_millis(STABLE_BLOCKER_REFRESH_MS - 1),
                    false,
                    false,
                )
                .is_none()
        );
        assert!(
            tracker
                .record_detection_at(
                    "term_a",
                    Some(("codex", blocked)),
                    t0 + Duration::from_millis(STABLE_BLOCKER_REFRESH_MS),
                    false,
                    false,
                )
                .is_some()
        );
    }

    #[test]
    fn screen_detect_tracker_closes_departed_agents_with_done() {
        let mut tracker = ScreenDetectTracker::default();
        assert!(
            tracker.record_detection("term_a", None).is_none(),
            "a terminal that never emitted stays silent"
        );

        tracker.record_detection("term_a", Some(("codex", detection(ScreenState::Working))));
        assert!(tracker.has_live_emission("term_a"));
        let done = tracker.record_detection("term_a", None);
        assert_eq!(
            done,
            Some(ScreenDetectEmission {
                terminal_id: "term_a".into(),
                agent: "codex".into(),
                state: AgentState::Done,
                matched_rule: None,
                visible_idle: false,
                visible_blocker: false,
                visible_working: false,
            })
        );
        assert!(!tracker.has_live_emission("term_a"));
        assert_eq!(tracker.record_detection("term_a", None), None, "done is an edge too");
    }

    #[test]
    fn screen_detect_tracker_keeps_prior_state_for_viewers_and_unknowns() {
        let mut tracker = ScreenDetectTracker::default();
        tracker.record_detection("term_a", Some(("codex", detection(ScreenState::Working))));

        let viewer = Detection {
            state: ScreenState::Unknown,
            skip_state_update: true,
            matched_rule: Some("transcript_viewer".into()),
            visible_idle: false,
            visible_blocker: false,
            visible_working: false,
        };
        assert_eq!(tracker.record_detection("term_a", Some(("codex", viewer))), None);

        let unknown = detection(ScreenState::Unknown);
        assert_eq!(tracker.record_detection("term_a", Some(("codex", unknown))), None);
        assert!(tracker.has_live_emission("term_a"), "working emission still owns the terminal");
    }

    #[test]
    fn screen_detect_tracker_flags_identity_edges_for_immediate_evaluation() {
        let mut tracker = ScreenDetectTracker::default();
        // Shell pane: no agent means no edge, first scan included.
        assert!(!tracker.note_foreground_agent("term_a", None));
        assert!(!tracker.note_foreground_agent("term_a", None));
        // codex launches: edge fires once, then the identity is steady.
        assert!(tracker.note_foreground_agent("term_a", Some("codex")));
        assert!(!tracker.note_foreground_agent("term_a", Some("codex")));
        // Swapping agents in place is an edge, and so is exiting.
        assert!(tracker.note_foreground_agent("term_a", Some("claude")));
        for attempt in 1..AGENT_MISS_CONFIRMATION_ATTEMPTS {
            assert!(
                !tracker.note_foreground_agent("term_a", None),
                "miss {attempt} must stay inside the confirmation window"
            );
            assert_eq!(tracker.foreground_agent("term_a"), Some("claude"));
        }
        assert!(tracker.note_foreground_agent("term_a", None));
        assert_eq!(tracker.foreground_agent("term_a"), None);
    }

    #[test]
    fn identity_edge_retries_a_failed_screen_read_without_new_output() {
        let mut tracker = ScreenDetectTracker::default();
        let t0 = Instant::now();
        let at = |milliseconds: u64| t0 + Duration::from_millis(milliseconds);

        // Establish a previously evaluated screen for one foreground agent.
        assert!(tracker.note_foreground_agent_at("term_a", Some("claude"), t0));
        assert!(tracker.observe_revision("term_a", 1, t0));
        tracker.record_detection_at(
            "term_a",
            Some(("claude", detection(ScreenState::Working))),
            t0,
            false,
            false,
        );

        // The process changes, but the first read after the edge is assumed
        // to fail. The retry must still be armed by the identity edge.
        assert!(tracker.note_foreground_agent_at("term_a", Some("codex"), at(100)));
        assert!(
            tracker.observe_revision("term_a", 1, at(QUIESCENCE_DEBOUNCE_MS)),
            "an identity edge must invalidate the old evaluated revision"
        );
    }

    #[test]
    fn screen_detect_tracker_resets_identity_misses_on_a_positive_probe() {
        let mut tracker = ScreenDetectTracker::default();
        assert!(tracker.note_foreground_agent("term_a", Some("codex")));
        for _ in 0..AGENT_MISS_CONFIRMATION_ATTEMPTS - 1 {
            assert!(!tracker.note_foreground_agent("term_a", None));
        }
        // A successful process probe prevents the previous misses from
        // carrying into the next disappearance window.
        assert!(!tracker.note_foreground_agent("term_a", Some("codex")));
        for _ in 0..AGENT_MISS_CONFIRMATION_ATTEMPTS - 1 {
            assert!(!tracker.note_foreground_agent("term_a", None));
        }
        assert!(tracker.note_foreground_agent("term_a", None));
    }

    #[test]
    fn screen_detect_tracker_process_exit_clears_identity_even_without_a_done_row() {
        let mut tracker = ScreenDetectTracker::default();
        let t0 = Instant::now();
        assert!(tracker.note_foreground_agent_at("term_a", Some("codex"), t0));
        assert!(tracker.record_detection_at("term_a", None, t0, true, true).is_none());
        assert_eq!(tracker.foreground_agent("term_a"), None);
        assert!(!tracker.startup_grace_active("term_a", t0 + Duration::from_secs(4)));
    }

    #[test]
    fn screen_detect_tracker_graces_new_identity_before_reading_the_screen() {
        let mut tracker = ScreenDetectTracker::default();
        let t0 = Instant::now();
        let at = |milliseconds: u64| t0 + Duration::from_millis(milliseconds);

        assert!(tracker.observe_revision("term_a", 1, t0));
        tracker.record_detection("term_a", Some(("codex", detection(ScreenState::Working))));
        assert!(!tracker.observe_revision("term_a", 2, at(100)));
        assert!(tracker.output_active("term_a", at(100)));
        assert!(tracker.note_foreground_agent_at("term_a", Some("codex"), t0));
        assert!(!tracker.output_active("term_a", at(100)));
        assert!(tracker.startup_grace_active("term_a", at(AGENT_STARTUP_GRACE_MS - 1)));
        assert!(!tracker.startup_grace_active("term_a", at(AGENT_STARTUP_GRACE_MS)));

        // Presence is published without screen evidence. The scanner's grace
        // check prevents a stale shell prompt from reaching record_detection.
        assert_eq!(
            tracker
                .record_identity_presence_at("term_a", "codex", t0)
                .map(|emission| emission.state),
            Some(AgentState::Idle)
        );
        assert!(!tracker.needs_identity_presence("term_a", "codex"));
        tracker.rollback_emission(&ScreenDetectEmission {
            terminal_id: "term_a".into(),
            agent: "codex".into(),
            state: AgentState::Idle,
            matched_rule: None,
            visible_idle: false,
            visible_blocker: false,
            visible_working: false,
        });
        assert!(tracker.needs_identity_presence("term_a", "codex"));

        // The scanner calls finish once the deadline passes. It clears the
        // evaluated revision so an unchanged viewport is read exactly once.
        assert!(tracker.finish_startup_grace("term_a", at(AGENT_STARTUP_GRACE_MS)));
        assert!(!tracker.finish_startup_grace("term_a", at(AGENT_STARTUP_GRACE_MS + 1)));
        assert!(!tracker.startup_grace_active("term_a", at(AGENT_STARTUP_GRACE_MS + 1)));
    }

    #[test]
    fn screen_detect_tracker_restarts_grace_for_an_agent_swap() {
        let mut tracker = ScreenDetectTracker::default();
        let t0 = Instant::now();
        let at = |milliseconds: u64| t0 + Duration::from_millis(milliseconds);

        assert!(tracker.note_foreground_agent_at("term_a", Some("codex"), t0));
        assert!(!tracker.note_foreground_agent_at("term_a", Some("codex"), at(500)));
        assert!(tracker.note_foreground_agent_at("term_a", Some("claude"), at(700)));
        assert!(tracker.startup_grace_active("term_a", at(700 + AGENT_STARTUP_GRACE_MS - 1)));
        assert!(!tracker.startup_grace_active("term_a", at(700 + AGENT_STARTUP_GRACE_MS)));
    }

    #[test]
    fn screen_detect_tracker_restarts_grace_for_same_agent_process_replacement() {
        let mut tracker = ScreenDetectTracker::default();
        let t0 = Instant::now();
        let at = |milliseconds: u64| t0 + Duration::from_millis(milliseconds);

        assert!(tracker.note_foreground_job_at("term_a", Some("codex"), Some(41), t0));
        assert!(!tracker.note_foreground_job_at("term_a", Some("codex"), Some(41), at(500)));
        assert!(tracker.note_foreground_job_at("term_a", Some("codex"), Some(42), at(700)));
        assert!(tracker.startup_grace_active("term_a", at(700 + AGENT_STARTUP_GRACE_MS - 1)));
        assert!(!tracker.startup_grace_active("term_a", at(700 + AGENT_STARTUP_GRACE_MS)));
    }

    #[test]
    fn same_agent_process_replacement_republishes_idle_presence() {
        let mut tracker = ScreenDetectTracker::default();
        let t0 = Instant::now();

        assert!(tracker.note_foreground_job_at("term_a", Some("codex"), Some(41), t0));
        let first = tracker.record_identity_presence_at("term_a", "codex", t0).unwrap();
        tracker.commit_emission(&first);
        assert!(!tracker.needs_identity_presence("term_a", "codex"));

        assert!(tracker.note_foreground_job_at(
            "term_a",
            Some("codex"),
            Some(42),
            t0 + Duration::from_millis(1),
        ));
        assert!(tracker.needs_identity_presence("term_a", "codex"));
        let replacement = tracker
            .record_identity_presence_at("term_a", "codex", t0 + Duration::from_millis(1))
            .expect("replacement must emit presence even when state stays idle");
        assert_eq!(replacement.agent, "codex");
        assert_eq!(replacement.state, AgentState::Idle);
    }

    #[test]
    fn screen_detect_tracker_keeps_first_acquisition_osc_evidence_and_fences_replacements() {
        let mut tracker = ScreenDetectTracker::default();
        let t0 = Instant::now();

        assert!(tracker.note_foreground_job_at_with_revision(
            "term_a",
            Some("codex"),
            None,
            Some(41),
            t0,
        ));
        // Herdr keeps evidence emitted before the first process probe. The
        // userland equivalent does not require a revision on this edge.
        assert!(tracker.metadata_is_fresh("term_a", Some(41)));
        assert!(tracker.metadata_is_fresh("term_a", Some(40)));

        // A replacement must not inherit the previous process's OSC fields.
        assert!(tracker.note_foreground_job_at_with_revision(
            "term_a",
            Some("claude"),
            None,
            Some(41),
            t0,
        ));
        assert!(!tracker.metadata_is_fresh("term_a", Some(41)));
        assert!(!tracker.metadata_is_fresh("term_a", None));
        assert!(tracker.metadata_is_fresh("term_a", Some(42)));

        // A confirmed exit also leaves a fence. The host cannot clear its
        // retained fields, so the next acquisition waits for new output.
        for attempt in 0..AGENT_MISS_CONFIRMATION_ATTEMPTS {
            let edge =
                tracker.note_foreground_job_at_with_revision("term_a", None, None, Some(42), t0);
            assert_eq!(edge, attempt + 1 == AGENT_MISS_CONFIRMATION_ATTEMPTS);
        }
        assert!(tracker.note_foreground_job_at_with_revision(
            "term_a",
            Some("codex"),
            None,
            Some(42),
            t0,
        ));
        assert!(!tracker.metadata_is_fresh("term_a", Some(42)));
        assert!(tracker.metadata_is_fresh("term_a", Some(43)));

        // Once this terminal has supplied a generation anchor, a missing
        // revision cannot prove that retained metadata belongs to the new
        // process. Fail closed until the host reports a newer revision.
        assert!(!tracker.metadata_is_fresh("term_a", None));

        // If the catalog omitted the revision on a first acquisition, a later
        // revision does not change the first-acquisition policy. The evidence
        // may have been emitted before the process probe caught up.
        assert!(tracker.note_foreground_job_at_with_revision(
            "term_b",
            Some("codex"),
            None,
            None,
            t0,
        ));
        assert!(!tracker.note_foreground_job_at_with_revision(
            "term_b",
            Some("codex"),
            None,
            Some(41),
            t0,
        ));
        assert!(tracker.metadata_is_fresh("term_b", Some(41)));
        assert!(tracker.metadata_is_fresh("term_b", Some(42)));
    }

    #[test]
    fn screen_detect_tracker_keeps_first_acquisition_without_revision_unfenced() {
        let mut tracker = ScreenDetectTracker::default();
        let t0 = Instant::now();

        assert!(tracker.note_foreground_job_at_with_revision(
            "term_a",
            Some("codex"),
            None,
            None,
            t0,
        ));
        assert!(tracker.metadata_is_fresh("term_a", None));

        // Once a replacement is observed, a later revision enriches the
        // identity and starts the fence even if the edge had no revision.
        assert!(tracker.note_foreground_job_at_with_revision(
            "term_a",
            Some("claude"),
            None,
            None,
            t0,
        ));
        assert!(!tracker.note_foreground_job_at_with_revision(
            "term_a",
            Some("claude"),
            None,
            Some(9),
            t0,
        ));
        assert!(!tracker.metadata_is_fresh("term_a", Some(9)));
        assert!(tracker.metadata_is_fresh("term_a", Some(10)));
    }

    #[test]
    fn screen_detect_exit_does_not_use_local_scheduler_revision_as_osc_fence() {
        let mut tracker = ScreenDetectTracker::default();
        let t0 = Instant::now();

        // A daemon without stream revisions still uses a local screen key to
        // schedule reads. That key is not evidence about PTY generations.
        assert!(tracker.observe_revision("term_a", 7, t0));
        assert!(tracker.note_foreground_job_at_with_revision(
            "term_a",
            Some("codex"),
            None,
            None,
            t0,
        ));
        let started = tracker
            .record_detection_at(
                "term_a",
                Some(("codex", detection(ScreenState::Working))),
                t0,
                true,
                false,
            )
            .expect("agent state edge");
        tracker.commit_emission(&started);

        // The exit has no host revision. The compatibility path must remain
        // open; the local scheduler key must not become a durable fence.
        let ended = tracker
            .record_detection_at_with_revision("term_a", None, t0, true, true, None)
            .expect("exit edge");
        tracker.commit_emission(&ended);
        assert!(tracker.metadata_is_fresh("term_a", Some(1)));
    }

    #[test]
    fn screen_detect_tracker_emits_idle_presence_when_the_first_screen_asserts_nothing() {
        let mut tracker = ScreenDetectTracker::default();
        // First evaluation right after spawn hits a viewer/unknown screen:
        // presence must not wait for a stable screen.
        let viewer = Detection {
            state: ScreenState::Unknown,
            skip_state_update: true,
            matched_rule: Some("transcript_viewer".into()),
            visible_idle: false,
            visible_blocker: false,
            visible_working: false,
        };
        let presence = tracker.record_detection("term_a", Some(("codex", viewer)));
        assert_eq!(
            presence,
            Some(ScreenDetectEmission {
                terminal_id: "term_a".into(),
                agent: "codex".into(),
                state: AgentState::Idle,
                matched_rule: Some("transcript_viewer".into()),
                visible_idle: false,
                visible_blocker: false,
                visible_working: false,
            })
        );

        let unknown = detection(ScreenState::Unknown);
        assert_eq!(
            tracker
                .record_detection("term_b", Some(("codex", unknown)))
                .map(|emission| emission.state),
            Some(AgentState::Idle)
        );
    }

    #[test]
    fn screen_detect_tracker_prunes_closed_terminals_with_one_lookup_each() {
        const LIVE_COUNT: usize = 1_024;
        const CLOSED_COUNT: usize = 1_024;

        let mut tracker = ScreenDetectTracker::default();
        let live_ids: Vec<String> = (0..LIVE_COUNT).map(|index| format!("live-{index}")).collect();
        let closed_ids: Vec<String> =
            (0..CLOSED_COUNT).map(|index| format!("closed-{index}")).collect();
        for terminal_id in live_ids.iter().chain(&closed_ids) {
            tracker.record_detection(terminal_id, Some(("codex", detection(ScreenState::Working))));
        }

        let builds = Arc::new(AtomicUsize::new(0));
        let mut live = HashSet::with_capacity_and_hasher(
            LIVE_COUNT,
            CountingBuildHasher { builds: builds.clone() },
        );
        live.extend(live_ids.iter().map(String::as_str));
        builds.store(0, Ordering::Relaxed);

        tracker.retain_terminals(|terminal_id| live.contains(terminal_id));

        assert_eq!(
            builds.load(Ordering::Relaxed),
            LIVE_COUNT + CLOSED_COUNT,
            "retention must make one indexed membership lookup per tracked terminal",
        );
        assert!(live_ids.iter().all(|terminal_id| tracker.has_live_emission(terminal_id)));
        assert!(closed_ids.iter().all(|terminal_id| !tracker.has_live_emission(terminal_id)));
    }
}
