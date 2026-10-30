// SPDX-License-Identifier: GPL-3.0-or-later
public import Darwin
public import Foundation

/// Starts Computer Use as cmux Remote's worker (docs/cmux-remote.md). The App implements it
/// over the daemon (`remote-host-app`) and cmux Remote's app socket. The returned channel is
/// the worker's control pipe: its lines are the worker's, writing to it writes the worker's
/// stdin, and closing it stops the worker, as EOF on the helper's stdin did.
public nonisolated protocol ComputerUseRemoteSpawning: Sendable {
    func openComputerUse() async throws -> ComputerUseRemoteChannel
}

/// One open Computer Use channel through cmux Remote.
public nonisolated struct ComputerUseRemoteChannel: Sendable {
    /// The worker's pid (cmux Remote's child).
    public var pid: pid_t
    /// The connected app socket, after its opening exchange.
    public var socket: Int32
    /// cmux Remote's executable: the worker runs it, so the consent link checks its signature.
    public var executable: URL

    public init(pid: pid_t, socket: Int32, executable: URL) {
        self.pid = pid
        self.socket = socket
        self.executable = executable
    }
}

/// A remote worker as a helper child. Its stdout lines come from the channel; the channel's
/// end is the worker's exit (`exited`), since the worker is not this app's child.
nonisolated struct RemoteWorkerChild: Sendable {
    let child: ComputerUseHelperV2Child
    let exited: AsyncStream<Void>

    init(_ channel: ComputerUseRemoteChannel) {
        let (exited, signal) = AsyncStream.makeStream(of: Void.self)
        let raw = DisclaimedHelperSpawner.lines(from: dup(channel.socket))
        let (lines, sink) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(16))
        // task-owner: ends with the channel's stdout (the worker's exit or the host's end).
        Task.detached {
            for await line in raw { sink.yield(line) }
            sink.finish()
            signal.yield()
            signal.finish()
        }
        child = ComputerUseHelperV2Child(pid: channel.pid, input: channel.socket, lines: lines)
        self.exited = exited
    }
}

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
