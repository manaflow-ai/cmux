public import Foundation

/// Decides whether a classic migration runs and what it makes. Pure: no files, no daemon.
///
/// The rules that keep the migration one-time and duplicate-free:
/// - A workspace key the ledger has as done never comes over again in an
///   automatic run, even when classic changed it later (cmux-next's copy wins).
///   A manual run (Import Workspaces from Classic cmux) brings it back only
///   when its cmux-next workspace was closed.
/// - A key the ledger has as pending or created was cut off: its half-made
///   workspace is closed and it is made again.
/// - A group an earlier run made is reused while it exists, so a merge after
///   a downgrade puts new workspaces into the same group.
///
/// ```swift
/// let planner = ClassicMigrationPlanner()
/// let plan = planner.plan(snapshot, ledger: ledger, live: openWorkspaceIDs, liveGroups: groupIDs, mode: .automatic)
/// ```
public nonisolated struct ClassicMigrationPlanner: Sendable {
    /// Who started the run.
    public nonisolated enum Mode: Sendable {
        /// At launch, by itself.
        case automatic
        /// The person or an agent ran Import Workspaces from Classic cmux.
        case manual
    }

    /// Whether an automatic run starts at launch.
    public nonisolated enum Decision: Equatable, Sendable {
        case firstRun
        /// The last run was cut off.
        case resume
        /// Classic saved again since the last run (a downgrade, then this upgrade).
        case merge
        case skip(SkipReason)
    }

    public nonisolated enum SkipReason: Equatable, Sendable {
        /// Classic saved no session for any channel.
        case noClassicSession
        /// Classic has not saved since the last run.
        case unchanged
        /// Classic is running and may still save.
        case classicRunning
        /// The ledger is from a newer cmux-next, or does not decode.
        case ledgerNotUsable
        /// Turned off (`CMUX_NEXT_CLASSIC_MIGRATION=0`), or a debug build without opting in.
        case disabled
        /// cmux-next held workspaces before its first migration: classic's
        /// were recorded as seen (``ClassicMigrationPlanner/baseline(_:ledger:)``), none made.
        case inUseBefore
    }

    public init() {}

    /// Whether an automatic run starts at launch.
    ///
    /// - Parameters:
    ///   - load: what the ledger file held.
    ///   - source: the classic save that would be read; nil when classic has none.
    ///   - classicRunning: whether a classic cmux app is running now.
    public func decision(_ load: ClassicMigrationLedgerLoad, source: ClassicMigrationSource?, classicRunning: Bool) -> Decision {
        let ledger: ClassicMigrationLedger?
        switch load {
        case .newer, .unreadable: return .skip(.ledgerNotUsable)
        case .none: ledger = nil
        case .ledger(let saved): ledger = saved
        }
        guard let source else { return .skip(.noClassicSession) }
        guard let ledger else { return classicRunning ? .skip(.classicRunning) : .firstRun }
        // A cut-off run finishes from the save it started with, even while classic runs.
        if ledger.state == .inProgress { return .resume }
        if let last = ledger.source, last.isSameSave(as: source) { return .skip(.unchanged) }
        return classicRunning ? .skip(.classicRunning) : .merge
    }

    /// What a run makes from `snapshot`.
    ///
    /// - Parameters:
    ///   - snapshot: classic's saved session.
    ///   - ledger: the last run's record; nil for the first run.
    ///   - live: ids of cmux-next workspaces that exist now.
    ///   - liveGroups: ids of cmux-next groups that exist now.
    ///   - mode: automatic at launch or manual.
    public func plan(_ snapshot: ClassicSessionSnapshot, ledger: ClassicMigrationLedger?, live: Set<String>, liveGroups: Set<String>,
                     mode: Mode) -> ClassicMigrationPlan {
        var plan = ClassicMigrationPlan()
        var seen = Set<String>()
        var neededGroups: [String] = []
        let groupsByID = Dictionary(snapshot.windows.flatMap(\.groups).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for window in snapshot.windows {
            var coming: [ClassicSessionWorkspace] = []
            for workspace in window.workspaces {
                guard seen.insert(workspace.key).inserted else {
                    plan.skipped[workspace.key] = plan.skipped[workspace.key] ?? .duplicate
                    continue
                }
                if workspace.cloudVM != nil {
                    plan.skipped[workspace.key] = .cloudVM
                    continue
                }
                if let entry = ledger?.workspaces[workspace.key] {
                    switch entry.stage {
                    case .done, .skipped:
                        let reopen = mode == .manual && entry.stage == .done && !(entry.nextWorkspace.map { live.contains($0) } ?? false)
                        guard reopen else {
                            plan.skipped[workspace.key] = .alreadyMigrated
                            continue
                        }
                    case .pending, .created:
                        if let half = entry.nextWorkspace, live.contains(half) { plan.cleanup.append(half) }
                    }
                }
                coming.append(workspace)
                if let group = workspace.groupID, groupsByID[group] != nil, !neededGroups.contains(group) { neededGroups.append(group) }
            }
            // A pinned group comes over even with no member in this run, once.
            for group in window.groups where group.pinned && !neededGroups.contains(group.id) && ledger?.groups[group.id] == nil {
                neededGroups.append(group.id)
            }
            guard !coming.isEmpty else { continue }
            let selected = window.selectedWorkspace.flatMap { window.workspaces.indices.contains($0) ? window.workspaces[$0].key : nil }
            plan.windows.append(ClassicMigrationPlan.Window(
                frame: window.frame, selectedKey: coming.contains { $0.key == selected } ? selected : nil, workspaces: coming))
        }
        plan.groups = neededGroups.compactMap { id in
            groupsByID[id].map { group in
                let existing = ledger?.groups[id].flatMap { liveGroups.contains($0) ? $0 : nil }
                return ClassicMigrationPlan.Group(classic: group, existing: existing)
            }
        }
        return plan
    }

    /// `ledger` with every classic workspace in `snapshot` recorded as seen,
    /// none made: for a cmux-next that was in use before its first migration.
    /// A manual run still brings each one over (no cmux-next workspace is
    /// recorded for it); an automatic merge brings only later ones.
    public func baseline(_ snapshot: ClassicSessionSnapshot, ledger: ClassicMigrationLedger) -> ClassicMigrationLedger {
        var ledger = ledger
        for workspace in snapshot.workspaces where ledger.workspaces[workspace.key] == nil {
            ledger.workspaces[workspace.key] = workspace.cloudVM != nil
                ? ClassicMigrationLedger.Entry(stage: .skipped, reason: "cloud-vm")
                : ClassicMigrationLedger.Entry(stage: .done, reason: "baseline")
        }
        ledger.state = .completed
        return ledger
    }
}
