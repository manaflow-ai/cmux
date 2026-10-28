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
    typealias ProcessGroupSignaller = @Sendable (_ processGroupID: Int, _ signal: Int32) -> Bool
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
            kill(pid_t(-processGroupID), signal) == 0
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

    /// Revalidates the selected groups before each signal phase. Returns true
    /// only when the OS accepted SIGTERM for at least one group.
    func terminate(
        processGroupIDs: [Int],
        ttyDevice: Int64,
        census initialCensus: RunawaySessionCensus,
        selector: RunawaySessionSelector,
        shouldTerminate: @Sendable () async -> Bool = { true },
        shouldEscalate: @Sendable () async -> Bool = { true }
    ) async -> Bool {
        guard !processGroupIDs.isEmpty,
              let beforeTerm = await snapshotProvider().runawaySessionCensus() else { return false }
        guard let initialSession = initialCensus.sessionIdentifier(ttyDevice: ttyDevice, appProcessID: selector.appProcessID),
              beforeTerm.sessionIdentifier(ttyDevice: ttyDevice, appProcessID: selector.appProcessID) == initialSession else { return false }
        let eligible = selector.signallableProcessGroupIDs(ttyDevice: ttyDevice, in: beforeTerm) ?? []
        let continuing = beforeTerm.continuingProcessGroupIDs(eligible, since: initialCensus)
        guard await shouldTerminate(), !Task.isCancelled else { return false }
        let signalled = processGroupIDs.filter {
            continuing.contains($0) && signalProcessGroup($0, SIGTERM)
        }
        guard !signalled.isEmpty else { return false }
        // Without a complete census a reused group ID can't be ruled out.
        guard await waitForGraceDeadline(),
              let census = await snapshotProvider().runawaySessionCensus(),
              census.sessionIdentifier(ttyDevice: ttyDevice, appProcessID: selector.appProcessID) == initialSession else { return true }
        let signallable = selector.signallableProcessGroupIDs(ttyDevice: ttyDevice, in: census) ?? []
        // A group whose members all exited frees its ID; one that reappears
        // under it is another job and must not get SIGKILL.
        let liveGroups = census.continuingProcessGroupIDs(signallable, since: beforeTerm)
        guard await shouldEscalate(), !Task.isCancelled else { return true }
        for processGroupID in signalled where liveGroups.contains(processGroupID) {
            _ = signalProcessGroup(processGroupID, SIGKILL)
        }
        return true
    }
}
