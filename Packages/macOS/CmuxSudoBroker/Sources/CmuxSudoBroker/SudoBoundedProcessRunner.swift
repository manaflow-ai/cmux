import Darwin
import Foundation

struct SudoBoundedProcessRunner: Sendable {
    private let spawner: any SudoProcessSpawning
    private let inspector: any SudoProcessInspecting
    private let executionWaiter: SudoExecutionEventWaiter
    private let terminator: SudoProcessTreeTerminator
    private let now: @Sendable () -> Date

    init(
        spawner: any SudoProcessSpawning,
        inspector: any SudoProcessInspecting,
        signaler: any SudoProcessSignaling,
        now: @Sendable @escaping () -> Date = { .now }
    ) {
        self.spawner = spawner
        self.inspector = inspector
        executionWaiter = SudoExecutionEventWaiter(
            inspector: inspector
        )
        terminator = SudoProcessTreeTerminator(inspector: inspector, signaler: signaler)
        self.now = now
    }

    func spawn(_ command: SudoExecutionCommand) throws -> SudoSpawnedProcess {
        try spawner.spawn(command)
    }

    func wait(
        for process: SudoSpawnedProcess,
        deadline: Date
    ) -> SudoProcessOutcome {
        let timeout = max(0, deadline.timeIntervalSince(now()))
        switch executionWaiter.wait(for: process, after: timeout) {
        case .exited:
            return reap(process.identity.processIdentifier)
        case .authenticationFailed:
            return .authenticationFailed(
                cleanupSurvivors: terminateAndReap(process)
            )
        case .timedOut:
            return .timedOut(cleanupSurvivors: terminateAndReap(process))
        case .privilegedTimedOut:
            _ = reap(process.identity.processIdentifier)
            return .privilegedTimedOut
        case .privilegedCleanupFailed:
            _ = reap(process.identity.processIdentifier)
            return .privilegedCleanupFailed(
                cleanupSurvivors: privilegedSurvivors(process)
            )
        case .privilegedTransportFailed:
            _ = reap(process.identity.processIdentifier)
            return .privilegedTransportFailed
        case .failed:
            let survivors = terminateAndReap(process)
            return survivors.isEmpty
                ? .unavailable
                : .timedOut(cleanupSurvivors: survivors)
        }
    }

    func terminate(_ process: SudoSpawnedProcess) -> [SudoProcessIdentity] {
        terminateAndReap(process)
    }

    private func terminateAndReap(_ process: SudoSpawnedProcess) -> [SudoProcessIdentity] {
        process.io.close()
        let survivors = terminator.terminate(root: process.identity)
        if !survivors.contains(process.identity) {
            _ = reap(process.identity.processIdentifier)
        }
        return survivors
    }

    private func reap(_ processIdentifier: Int32) -> SudoProcessOutcome {
        var status: Int32 = 0
        var result: pid_t = 0
        repeat {
            result = waitpid(processIdentifier, &status, 0)
        } while result < 0 && errno == EINTR

        guard result == processIdentifier else {
            return .unavailable
        }
        let terminationSignal = status & 0x7f
        if terminationSignal == 0 {
            return .exited((status >> 8) & 0xff)
        }
        return .signaled(terminationSignal)
    }

    private func privilegedSurvivors(_ process: SudoSpawnedProcess) -> [SudoProcessIdentity] {
        guard let approvedScriptURL = process.approvedScriptURL else { return [] }
        return SudoOrphanProcessInventory(inspector: inspector)
            .identitiesByScriptPath(approvedScriptURLs: [approvedScriptURL])[
                approvedScriptURL.standardizedFileURL.path
            ] ?? []
    }
}
