import CmuxMemoryPressure
import Darwin
import Foundation

/// Stops process groups in one terminal session: SIGTERM now, then SIGKILL
/// to the groups that are still signallable on the same tty in a fresh,
/// complete census after a bounded grace deadline, and still hold a process
/// that was their member in the census the groups were chosen from. Shared by the automatic
/// critical-pressure responder and the user's Stop Process Tree action.
struct RunawayPaneTreeTerminator: Sendable {
    typealias SnapshotProvider = @Sendable () async -> CmuxTopProcessSnapshot
    typealias ProcessGroupSignaller = @Sendable (_ processGroupID: Int, _ signal: Int32) -> Void
    typealias GraceDeadline = @Sendable () async -> Bool

    let snapshotProvider: SnapshotProvider
    let signalProcessGroup: ProcessGroupSignaller
    let waitForGraceDeadline: GraceDeadline

    init(
        snapshotProvider: @escaping SnapshotProvider = {
            // Selection is tty-scoped, so the census skips per-process
            // environment reads while memory is under pressure.
            await CmuxTopProcessSnapshot.capture(includeCMUXScope: false)
        },
        signalProcessGroup: @escaping ProcessGroupSignaller = { processGroupID, signal in
            _ = kill(pid_t(-processGroupID), signal)
        },
        waitForGraceDeadline: @escaping GraceDeadline = {
            do {
                // Genuine SIGTERM grace deadline; cancellation skips escalation.
                try await ContinuousClock().sleep(for: .seconds(3))
                return true
            } catch {
                return false
            }
        }
    ) {
        self.snapshotProvider = snapshotProvider
        self.signalProcessGroup = signalProcessGroup
        self.waitForGraceDeadline = waitForGraceDeadline
    }

    /// Signals `processGroupIDs` on `ttyDevice`, chosen from `census`, and
    /// escalates survivors. `shouldEscalate` is asked after the grace
    /// deadline, so a guard that was turned off meanwhile suppresses SIGKILL.
    func terminate(
        processGroupIDs: [Int],
        ttyDevice: Int64,
        census initialCensus: RunawaySessionCensus,
        selector: RunawaySessionSelector,
        shouldEscalate: @Sendable () async -> Bool = { true }
    ) async {
        guard !processGroupIDs.isEmpty else { return }
        for processGroupID in processGroupIDs {
            signalProcessGroup(processGroupID, SIGTERM)
        }
        // Without a complete census a reused group ID can't be ruled out.
        guard await waitForGraceDeadline(),
              await shouldEscalate(),
              let census = await snapshotProvider().runawaySessionCensus() else { return }
        let signallable = selector.signallableProcessGroupIDs(ttyDevice: ttyDevice, in: census) ?? []
        // A group whose members all exited frees its ID; one that reappears
        // under it is another job and must not get SIGKILL.
        let liveGroups = census.continuingProcessGroupIDs(signallable, since: initialCensus)
        for processGroupID in processGroupIDs where liveGroups.contains(processGroupID) {
            signalProcessGroup(processGroupID, SIGKILL)
        }
    }
}
