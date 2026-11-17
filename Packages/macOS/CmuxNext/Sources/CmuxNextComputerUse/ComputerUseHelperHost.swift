// SPDX-License-Identifier: GPL-3.0-or-later
public import Darwin
public import Foundation
import CmuxNextCompat

/// Starts Computer Use as cmux Computer Use's worker (docs/computer-use-helper.md). The App implements it
/// over the daemon (`helper-host-app`) and cmux Computer Use's app socket. The returned channel is
/// the worker's control pipe: its lines are the worker's, writing to it writes the worker's
/// stdin, and closing it stops the worker, as EOF on the helper's stdin did.
public nonisolated protocol ComputerUseHelperHostSpawning: Sendable {
    /// Whether the daemon runs cmux Computer Use now (else the in-app helper runs, as before).
    func isAvailable() async -> Bool
    func openComputerUse() async throws -> ComputerUseHelperHostChannel
}

/// Computer Use through cmux Computer Use from a closure: the host starts a worker for each channel.
public nonisolated struct ComputerUseHelperHostSource: ComputerUseHelperHostSpawning {
    let available: @Sendable () async -> Bool
    let open: @Sendable () async throws -> ComputerUseHelperHostChannel

    public init(available: @escaping @Sendable () async -> Bool, open: @escaping @Sendable () async throws -> ComputerUseHelperHostChannel) {
        self.available = available
        self.open = open
    }

    public func isAvailable() async -> Bool { await available() }
    public func openComputerUse() async throws -> ComputerUseHelperHostChannel { try await open() }

    /// cmux Computer Use's executable in this app's embedded bundle (the worker runs it), or nil.
    public static func executable(bundle: Bundle = .main) -> URL? {
        for name in ["cmux Helper Host.app", "cmux Helper Host (dev).app"] {
            let url = bundle.bundleURL.appending(path: "Contents/Library/\(name)/Contents/MacOS/cmux-helper-host")
            if FileManager.checked.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }
}

/// One open Computer Use channel through cmux Computer Use.
public nonisolated struct ComputerUseHelperHostChannel: Sendable {
    /// The worker's pid (cmux Computer Use's child).
    public var pid: pid_t
    /// The connected app socket, after its opening exchange.
    public var socket: Int32
    /// cmux Computer Use's executable: the worker runs it, so the consent link checks its signature.
    public var executable: URL

    public init(pid: pid_t, socket: Int32, executable: URL) {
        self.pid = pid
        self.socket = socket
        self.executable = executable
    }
}

/// A helper host worker as a helper child. Its stdout lines come from the channel; the channel's
/// end is the worker's exit (`exited`), since the worker is not this app's child.
nonisolated struct HelperHostWorkerChild: Sendable {
    let child: ComputerUseHelperV2Child
    let exited: AsyncStream<Void>

    init(_ channel: ComputerUseHelperHostChannel) {
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
