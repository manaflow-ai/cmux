import Darwin
package import Foundation
import CmuxNextWakeups

/// Secret startup bytes stay in memory and go only to the verified child-created channel.
package struct NativeCloudLinkStartup: Sendable, CustomDebugStringConvertible {
    let bytes: Data
    let publicKey: String
    let recheck: @Sendable () async throws -> Void
    package var debugDescription: String { "NativeCloudLinkStartup(redacted)" }
}

/// One app-owned Native link. The app stops it when its selected account/team/mesh ends.
package actor NativeCloudLinkChild {
    private static let blockingWork = BackgroundWork(label: "com.cmuxterm.next.native-link")
    package struct Ready: Sendable {
        package let status: String
        package let pid: Int32
        package let socket: String
    }

    private struct LinkReadyLine: Decodable {
        let event: String
        let native: Bool
        let socket: String
        let pid: Int32
        let wg_public_key: String
    }

    private let bundleURL: URL
    private let publisher: NativeCloudExecutable.Publisher
    private let directory: URL
    private let home: URL
    private let prepare: @Sendable () async throws -> NativeCloudLinkStartup
    private let reply: @Sendable (Data) async throws -> Data
    private var generation: UInt64 = 0
    private var starting: Task<String, any Error>?
    private var serving: Task<Void, Never>?
    private var child: ChildProcess?
    private var stream: NativeBrokerStream?
    private var socket: String?
    private var childPID: Int32?

    package init(bundleURL: URL, publisher: NativeCloudExecutable.Publisher, directory: URL, home: URL,
                 prepare: @escaping @Sendable () async throws -> NativeCloudLinkStartup,
                 reply: @escaping @Sendable (Data) async throws -> Data) {
        self.bundleURL = bundleURL; self.publisher = publisher; self.directory = directory; self.home = home
        self.prepare = prepare; self.reply = reply
    }

    package func socketPath() async throws -> String {
        if let socket, child?.isRunning == true { return socket }
        if let starting { return try await starting.value }
        let epoch = generation
        let task = Task { try await self.launch(epoch: epoch) }
        starting = task
        defer { if starting == task { starting = nil } }
        return try await task.value
    }

    /// Ensures the verified child is serving and returns the exact ready
    /// process identity and socket announced by that child.
    package func ensure() async throws -> Ready {
        if let socket, let pid = childPID, child?.isRunning == true {
            return Ready(status: "running", pid: pid, socket: socket)
        }
        let socket = try await socketPath()
        guard let pid = childPID else { throw POSIXError(.ESRCH) }
        return Ready(status: "started", pid: pid, socket: socket)
    }

    package func stop() async {
        generation &+= 1
        starting?.cancel(); serving?.cancel(); serving = nil
        child?.terminateProcessOnly(); child = nil; childPID = nil; socket = nil
        await stream?.close(); stream = nil
    }

    private func check(_ epoch: UInt64) throws {
        try Task.checkCancellation()
        guard epoch == generation else { throw CancellationError() }
    }

    private func launch(epoch: UInt64) async throws -> String {
        let startup = try await prepare()
        try check(epoch)
        guard !startup.bytes.isEmpty, startup.bytes.count <= 4096,
              let bundle = Bundle(url: bundleURL) else { throw POSIXError(.EACCES) }
        let executable = try NativeCloudExecutable(bundle: bundle, publisher: publisher)
        let (parent, inherited) = try NativeBrokerDescriptor.pair()
        defer { Darwin.close(parent) }
        let input = FileHandle(fileDescriptor: inherited, closeOnDealloc: true)
        defer { try? input.close() }
        let process = ChildProcess(executable: executable.binary,
            arguments: ["link", "serve", "--native-cloud-broker-fd", "0", "--state-dir", directory.path],
            environment: ["HOME": home.path])
        child = process
        do {
            try process.start(inheritedInput: input)
            try input.close()
            guard let pid = process.pid, let started = NativeCloudProcessStart(pid: pid) else { throw POSIXError(.EACCES) }
            childPID = pid
            // task-owner: bounded startup task; cancellation stops the owned child and closes its peer.
            let received = Task { try await Self.blockingWork.run(.userVisible, mayBlock: .system) {
                try NativeBrokerDescriptor.receive(parent)
            } }
            var fd: Int32? = try await received.value
            defer { if let fd { Darwin.close(fd) } }
            try check(epoch)
            guard let descriptor = fd else { throw POSIXError(.EPROTO) }
            try executable.verify(descriptor: descriptor, child: process, started: started)
            let transport = NativeBrokerStream(descriptor: descriptor)
            fd = nil; stream = transport
            try await startup.recheck()
            try check(epoch)
            try executable.verify(descriptor: descriptor, child: process, started: started)
            var bytes = startup.bytes; bytes.append(0x0A)
            let payload = bytes
            try await withDeadline(.seconds(5), label: "Native key handoff") { try await transport.send(payload) }
            let ready: LinkReadyLine = try await process.firstLine(within: .seconds(10), label: "Native link startup") { line in
                try? JSONDecoder().decode(LinkReadyLine.self, from: Data(line.utf8))
            }
            try check(epoch)
            guard ready.event == "link-ready", ready.native, ready.pid == pid, ready.wg_public_key == startup.publicKey,
                  ready.socket.hasPrefix("/"), ready.socket.utf8.count <= 103 else { throw POSIXError(.EPROTO) }
            try executable.verify(descriptor: descriptor, child: process, started: started)
            socket = ready.socket
            // task-owner: serving; cancelled with the child in stop() and on any protocol/identity failure.
            serving = Task { [weak self, reply] in
                do {
                    try await Self.serve(transport, reply: reply) { [weak self] in
                        guard let self else { throw CancellationError() }
                        try await self.check(epoch)
                        try executable.verify(descriptor: descriptor, child: process, started: started)
                    }
                } catch { }
                await self?.ended(epoch: epoch)
            }
            return ready.socket
        } catch {
            process.terminateProcessOnly()
            if child === process {
                child = nil; childPID = nil; socket = nil
                await stream?.close(); stream = nil
            }
            throw error
        }
    }

    private static func serve(_ transport: NativeBrokerStream,
                              reply: @Sendable (Data) async throws -> Data,
                              verify: @escaping @Sendable () async throws -> Void) async throws {
        var buffer = Data(), next: UInt64 = 1
        for try await chunk in transport.chunks {
            buffer.append(chunk)
            guard buffer.count <= 4097 else { throw POSIXError(.EMSGSIZE) }
            guard let end = buffer.firstIndex(of: 0x0A) else { continue }
            guard end == buffer.index(before: buffer.endIndex) else { throw POSIXError(.EPROTO) }
            let line = Data(buffer[..<end]); buffer.removeAll(keepingCapacity: true)
            let request = try NativeCloudBrokerRequest(line)
            guard request.id == next, next < UInt64.max else { throw POSIXError(.EPROTO) }
            next += 1
            try await verify()
            var answer = try await reply(line)
            try await verify()
            answer.append(0x0A)
            let payload = answer
            try await withDeadline(.seconds(5), label: "Native broker reply") { try await transport.send(payload) }
        }
        guard buffer.isEmpty else { throw POSIXError(.EPROTO) }
    }

    private func ended(epoch: UInt64) async {
        guard epoch == generation else { return }
        await stop()
    }

    deinit { starting?.cancel(); serving?.cancel(); child?.terminateProcessOnly() }
}
