// SPDX-License-Identifier: GPL-3.0-or-later
public import Darwin
public import Foundation
import CmuxNextCompat

/// Starts Computer Use as cmux Remote's worker (docs/cmux-remote.md). The App implements it
/// over the daemon (`remote-host-app`) and cmux Remote's app socket. The returned channel is
/// the worker's control pipe: its lines are the worker's, writing to it writes the worker's
/// stdin, and closing it stops the worker, as EOF on the helper's stdin did.
public nonisolated protocol ComputerUseRemoteSpawning: Sendable {
    func openComputerUse() async throws -> ComputerUseRemoteChannel
}

/// Computer Use through cmux Remote from a closure: the host starts a worker for each channel.
public nonisolated struct ComputerUseRemoteSource: ComputerUseRemoteSpawning {
    let open: @Sendable () async throws -> ComputerUseRemoteChannel

    public init(open: @escaping @Sendable () async throws -> ComputerUseRemoteChannel) {
        self.open = open
    }

    public func openComputerUse() async throws -> ComputerUseRemoteChannel { try await open() }

    /// cmux Remote's executable in this app's embedded bundle (the worker runs it), or nil.
    public static func executable(bundle: Bundle = .main) -> URL? {
        for name in ["cmux Remote.app", "cmux Remote (dev).app"] {
            let url = bundle.bundleURL.appending(path: "Contents/Library/\(name)/Contents/MacOS/cmux-remote")
            if FileManager.checked.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }
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
        let (exited, signal) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let raw = DisclaimedHelperSpawner.lines(from: dup(channel.socket))
        let (lines, sink) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(16))
        // task-owner: ends with the channel's stdout (the worker's exit or the host's end).
        Task.detached(priority: .userInitiated) {
            for await line in raw { sink.yield(line) }
            sink.finish()
            signal.yield()
            signal.finish()
        }
        child = ComputerUseHelperV2Child(pid: channel.pid, input: channel.socket, lines: lines)
        self.exited = exited
    }
}
