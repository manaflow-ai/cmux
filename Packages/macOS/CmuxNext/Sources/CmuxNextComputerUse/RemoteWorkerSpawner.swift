// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// The spawner side of a remote worker: never spawns or signals (cmux Remote owns the
/// worker; closing the channel stops it), and the exit watch is the channel's end.
nonisolated struct RemoteWorkerSpawner: ComputerUseHelperV2Spawning {
    let exited: AsyncStream<Void>

    func spawn(executable: URL, environment: [String: String], logPath: String) throws -> ComputerUseHelperV2Child {
        throw DisclaimedHelperSpawner.Failure.disclaimUnavailable
    }

    func terminate(_ pid: pid_t) {}

    @MainActor func watchExit(of pid: pid_t, onExit: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        let exited = self.exited
        // task-owner: the returned closure cancels it; it ends at the channel's end.
        let task = Task { @MainActor in
            for await _ in exited {
                onExit()
                return
            }
        }
        return { task.cancel() }
    }
}
