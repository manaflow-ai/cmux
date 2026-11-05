public import CmuxNextDaemon
public import CmuxNextDesign
public import CmuxNextTabs
import Foundation

/// Turns the status facts the daemon publishes about a tab into
/// `StatusReport`s, and merges them per tab and per workspace with
/// `StatusStack` (plans/cmux-next/status-indicators.md). The app only
/// renders: every fact here is written by its owner (agent hooks through
/// the session host; running shell commands from the terminal record's
/// `extra.busy`; `workspace_status` entries and OSC 9;4 terminal progress
/// once the app reads them).
public struct StatusMapping {
    public static let shared = Self()

    /// The local acpmux turn states (agent chat tabs).
    let turns: AgentTurnStateStore
    /// This client's seen OSC 7501 `done` and `error` records.
    let seen: ProgramStatusSeenStore

    public init(turns: AgentTurnStateStore = .shared, seen: ProgramStatusSeenStore = .shared) {
        self.turns = turns
        self.seen = seen
    }

    /// The reports one tab contributes.
    public func reports(_ tab: TabModel) -> [StatusReport] {
        var reports: [StatusReport] = []
        if let agent = tab.agent, let state = state(agent.state), !yieldsToProgram(agent, tab.programStatus) {
            reports.append(StatusReport(id: "agent:\(tab.id)", source: .agent, state: state,
                                        label: agent.agent, updatedAtMs: agent.updatedAtMs))
        }
        if let record = ProgramStatusRecord.strongest(current(seen.visible(tab), agent: tab.agent)), let state = state(record) {
            // The title only: `app` is a machine name, never the only label.
            reports.append(StatusReport(id: "program:\(tab.id)", source: .program, state: state, label: record.title))
        }
        if let ref = tab.agentSession, let turn = visibleTurn(tab) {
            reports.append(StatusReport(id: "acp:\(ref.session ?? tab.id)", source: .agent, state: state(turn), label: ref.harness))
        }
        if let report = command(tab) { reports.append(report) }
        return reports
    }

    /// A plain shell command (the daemon's `extra.busy`) that has run `status.inferCommandBusyAfter`:
    /// busy, the weakest source. A younger one arms the tab's one-shot recheck for when it comes of age.
    /// An agent's terminal shows its own hook or turn state instead: the agent CLI is one long command
    /// that would look busy while it waits at its prompt.
    func command(_ tab: TabModel, nowMs: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)) -> StatusReport? {
        let behavior = DesignSettings.shared.statusBehavior
        guard behavior.inferCommandBusy, tab.agent == nil, tab.agentSession == nil, var since = tab.commandSinceMs else { return nil }
        _ = tab.commandRecheck
        // A daemon whose clock runs ahead (another machine) counts from when this client saw the command.
        if let seen = tab.commandSeenAt { since = min(since, UInt64(seen.timeIntervalSince1970 * 1000)) }
        let age = nowMs > since ? nowMs - since : 0
        let after = UInt64(behavior.inferCommandBusyAfter * 1000)
        guard age >= after else {
            tab.recheckCommand(after: .milliseconds(after - age))
            return nil
        }
        return StatusReport(id: "command:\(tab.id)", source: .command, state: .busy(progress: nil), updatedAtMs: since)
    }

    /// Roster sources that infer state from the screen (the agent plugin,
    /// legacy `detected`), unlike a hook or an OSC 7501 report the program
    /// sends itself.
    static let detectorSources: Set<String> = ["plugin", "detected"]

    /// The roster report and the terminal's OSC 7501 records are two reports of one agent, and the
    /// newer one is its state, so a stale `working` in either source shows no spinner.
    ///
    /// A roster report gives way to a record reported later: a hook roster that never saw its
    /// turn end (a missed Stop, a restart) yields to the program's own later `done` or `idle`. A
    /// detector's report also yields to a record of the same time: an explicit report is never
    /// hidden by a guess. A record without a report time (an older host) counts as fresher.
    func yieldsToProgram(_ agent: AgentStatus, _ records: [ProgramStatusRecord]) -> Bool {
        let detector = agent.source.map(Self.detectorSources.contains) ?? false
        return records.contains { record in
            let at = record.updatedAtMs ?? .max
            return detector ? at >= agent.updatedAtMs : at > agent.updatedAtMs
        }
    }

    /// The OSC 7501 records still current against the terminal's hook roster: a `working` or
    /// `blocked` record reported before the agent's latest hook is stale. Codex keeps reporting
    /// `working` after its turn ends while a background terminal runs, and its Stop hook (idle)
    /// is the newer fact (user, Oct 30). A `done` or `error` record stays: it is an unseen outcome
    /// for the tab's badge, not a state. A detector's guess outranks no record.
    func current(_ records: [ProgramStatusRecord], agent: AgentStatus?) -> [ProgramStatusRecord] {
        guard let agent, !records.isEmpty, !(agent.source.map(Self.detectorSources.contains) ?? false) else { return records }
        return records.filter { record in
            guard record.state == .working || record.state == .blocked, let at = record.updatedAtMs else { return true }
            return at >= agent.updatedAtMs
        }
    }

    /// The turn state still to show. acpmux owns what the person has seen of
    /// a chat (cx-n8ou): a completed turn is `done` only while it is unread.
    public func visibleTurn(_ tab: TabModel) -> AgentTurnState? {
        turn(tab)
    }

    /// The acpmux turn state of an agent chat tab, nil for every other tab.
    public func turn(_ tab: TabModel) -> AgentTurnState? {
        tab.agentSession.flatMap(turns.state(for:))
    }

    /// An acpmux turn or an OSC 7501 program waits for the user (the tab's
    /// still attention badge).
    public func needsInput(_ tab: TabModel) -> Bool {
        turn(tab) == .needsInput || ProgramStatusRecord.strongest(current(tab.programStatus, agent: tab.agent))?.state == .blocked
    }

    /// What the tab's strongest blocked OSC 7501 record waits for
    /// (permission, question, auth), for the tab's needs-input badge; nil
    /// when nothing blocks or the program named no kind.
    public func blockedKind(_ tab: TabModel) -> StatusBlockedKind? {
        guard let record = ProgramStatusRecord.strongest(current(tab.programStatus, agent: tab.agent)), record.state == .blocked else { return nil }
        return record.kind.flatMap { StatusBlockedKind(rawValue: $0.rawValue) }
    }

    /// An unseen OSC 7501 outcome for the tab's badge: `error` is a failure,
    /// `done` a success, until the user looks at the terminal. Nil while a
    /// stronger record (blocked, working) is live or nothing is unseen.
    /// An agent chat's failed turn, or one that completed unwatched, is the
    /// same outcome (acpmux owns both facts).
    public func outcome(_ tab: TabModel) -> TabStatus? {
        switch ProgramStatusRecord.strongest(seen.visible(tab))?.state {
        case .error?: return .failure
        case .done?: return .success
        default: break
        }
        switch visibleTurn(tab) {
        case .failed?, .lost?: return .failure
        case .done?: return .success
        default: return nil
        }
    }

    /// The shown OSC 7501 record's title and message for a hover detail (cx-6so.36.9): program
    /// text, untrusted, folded to one plain line after the program's `app` name, so it says
    /// whose words they are; nil when it has neither or nothing shows.
    public func detail(_ tab: TabModel) -> String? {
        guard let record = ProgramStatusRecord.strongest(seen.visible(tab)) else { return nil }
        let parts = [record.title, record.msg].compactMap { $0?.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return (record.app.map { "\($0): " } ?? "") + parts.joined(separator: " · ")
    }

    /// One tab's merged status.
    public func summary(_ tab: TabModel) -> StatusSummary {
        StatusStack.resolve(reports(tab), honoring: honored)
    }

    /// The strongest loading or working report of one tab, for the tab's
    /// icon slot: a waiting or failed source does not hide another source's
    /// mark there, because the tab's badge already marks those states.
    /// Agent work leaves the slot when `showAgentWorkingOnTabs` is off.
    public func loading(_ tab: TabModel) -> StatusSummary {
        let showsWorking = DesignSettings.shared.statusIndicator.showsAgentWorkingOnTabs
        return StatusStack.resolve(reports(tab).filter { $0.state.isLoading || ($0.state.isWorking && showsWorking) },
                                   honoring: honored)
    }

    /// Some tab of a workspace has agent work (an acpmux turn, a hook or an
    /// OSC 7501 `working` record), even while a stronger state (waiting)
    /// wins the row's merged status: the row's working slot
    /// (`WorkspaceRowContent.showsWorking`).
    public func isWorking(tabs: [TabModel]) -> Bool {
        tabs.contains { tab in reports(tab).contains { $0.state.isWorking } }
    }

    /// A workspace's merged status over its tabs and its `cmux status set` entries.
    public func summary(tabs: [TabModel], status: WorkspaceStatus? = nil) -> StatusSummary {
        StatusStack.resolve(tabs.flatMap(reports) + reports(status), honoring: honored)
    }

    /// A workspace's merged status, each tab's own (a hover card tab row's mark) and whether any tab has
    /// agent work, from one read of each tab's reports: ``summary(tabs:status:)``, ``summary(_:)``
    /// per tab and ``isWorking(tabs:)`` at once (u9696, Lawrence's scratch/a-hover-tabs).
    public func summaries(tabs: [TabModel], status: WorkspaceStatus? = nil)
        -> (workspace: StatusSummary, tabs: [StatusIndicatorState], working: Bool) {
        let honored = honored
        var all: [StatusReport] = []
        var states: [StatusIndicatorState] = []
        states.reserveCapacity(tabs.count)
        var working = false
        for tab in tabs {
            let own = reports(tab)
            if own.isEmpty {
                states.append(.idle)
                continue
            }
            states.append(StatusStack.resolve(own, honoring: honored).state)
            working = working || own.contains { $0.state.isWorking }
            all += own
        }
        return (StatusStack.resolve(all + reports(status), honoring: honored), states, working)
    }

    /// The reports of a workspace's status entries that carry a state (`cmux status set --state`,
    /// `status run`; cx-lko8w): busy with its progress, waiting, error, success. `info` and plain
    /// lines draw only their text. The daemon clears owned entries (TTL, owner exit).
    public func reports(_ status: WorkspaceStatus?) -> [StatusReport] {
        (status?.entries ?? []).compactMap { entry in
            let state: StatusIndicatorState? = switch entry.state {
            case "busy": .busy(progress: entry.progress.map { min(max($0, 0), 1) })
            case "waiting": .waiting
            case "error": .error
            case "success": .success
            default: nil
            }
            guard let state else { return nil }
            return StatusReport(id: "status:\(entry.key)", source: .explicit, state: state, label: entry.text,
                                style: entry.style.flatMap(StatusIndicatorStyle.init(rawValue:)))
        }
    }

    /// Sources whose style hint wins (`appearance.statusIndicator.honorStatusStyle`).
    var honored: Set<StatusReport.Source> { DesignSettings.shared.statusIndicator.honoredStyleSources }

    /// Agent hook state as an indicator state. `done` is not shown here:
    /// the tab's status badge marks it, and a finished agent is not loading.
    func state(_ agent: AgentState) -> StatusIndicatorState? {
        switch agent {
        case .working: .working
        case .blocked: .waiting
        case .idle, .done, .unknown: nil
        }
    }

    /// An OSC 7501 record as an indicator state. `reports` passes only
    /// records still to show, so a `done` or `error` here is unseen.
    func state(_ record: ProgramStatusRecord) -> StatusIndicatorState? {
        switch record.state {
        case .working: .working(progress: record.progress.map { Double($0) / 100 })
        case .blocked: .waiting(kind: record.kind.flatMap { StatusBlockedKind(rawValue: $0.rawValue) })
        case .error: .error
        case .done: .success
        case .idle: nil
        }
    }

    /// An acpmux turn state as an indicator state.
    func state(_ turn: AgentTurnState) -> StatusIndicatorState {
        switch turn {
        case .working: .working
        case .needsInput: .waiting
        case .failed, .lost: .error
        case .done: .success
        }
    }
}
