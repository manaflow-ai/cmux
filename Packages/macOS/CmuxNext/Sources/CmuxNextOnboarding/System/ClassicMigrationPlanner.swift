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
        .skip(.disabled)
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
        ClassicMigrationPlan()
    }

    /// `ledger` with every classic workspace in `snapshot` recorded as seen,
    /// none made: for a cmux-next that was in use before its first migration.
    /// A manual run still brings each one over (no cmux-next workspace is
    /// recorded for it); an automatic merge brings only later ones.
    public func baseline(_ snapshot: ClassicSessionSnapshot, ledger: ClassicMigrationLedger) -> ClassicMigrationLedger {
        ledger
    }
}
