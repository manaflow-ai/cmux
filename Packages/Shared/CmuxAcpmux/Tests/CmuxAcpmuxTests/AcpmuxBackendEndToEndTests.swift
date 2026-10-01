import CmuxAcpmux
import CmuxConversation
import CryptoKit
import Foundation
import Testing

/// Drives a real acpmux daemon (set `ACPMUX_BIN`, and `ACPMUX_FAKE_AGENT` to
/// its `tests/fake_agent.py`) through `AcpmuxBackend` and
/// `ConversationModel`, over its Unix socket.
@MainActor
struct AcpmuxBackendEndToEndTests {
    struct Daemon {
        let home: URL
        let process: Process
        var socket: String { home.appendingPathComponent("acpmux.sock").path }

        static func start() throws -> Daemon? {
            let env = ProcessInfo.processInfo.environment
            guard let bin = env["ACPMUX_BIN"], let fake = env["ACPMUX_FAKE_AGENT"] else { return nil }
            let home = URL(fileURLWithPath: "/tmp/acpmux-swift-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let config = #"{"harnesses":{"fake":{"argv":["python3","\#(fake)"]}},"defaultHarness":"fake","permissionPolicy":"approve-all","store":{"attachmentGraceMs":120000}}"#
            try config.write(to: home.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = ["daemon", "run", "--no-web", "--exit-with-parent", String(ProcessInfo.processInfo.processIdentifier)]
            p.environment = ["HOME": home.path, "ACPMUX_HOME": home.path, "ACPMUX_LOGIN_ENV": "0", "PATH": "/usr/bin:/bin"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            return Daemon(home: home, process: p)
        }

        func stop() {
            // SIGTERM is a clean shutdown; not waited for on the main actor.
            process.terminate()
            try? FileManager.default.removeItem(at: home)
        }
    }

    func eventually(_ what: String, timeout: Duration = .seconds(20), _ check: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !check() {
            if ContinuousClock.now > deadline { Issue.record("timed out waiting for \(what)"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func text(_ model: ConversationModel) -> [String] {
        model.state.items.compactMap { item in
            if case let .message(m) = item.kind { return "\(m.role == .user ? "U" : "A"):\(m.text)" }
            return nil
        }
    }

    func delivery(_ model: ConversationModel, _ id: ClientMessageID) -> DeliveryState? {
        for item in model.state.items {
            if case let .message(m) = item.kind, m.clientMessageID == id { return m.delivery }
        }
        return nil
    }

    func makeModel(_ daemon: Daemon, id: ConversationID? = nil) -> (ConversationModel, AcpmuxBackend) {
        let socket = daemon.socket
        let backend = AcpmuxBackend(opener: UnixSocketStreamOpener { socket }, clientName: "swift-test", singleAttachment: false)
        let outbox = FileOutboxStore(directory: daemon.home.appendingPathComponent("outbox"))
        let model = ConversationModel(backend: backend, conversationID: id, settings: ConversationSettings(agent: "fake", workingDirectory: "/tmp"), outbox: outbox, outboxKey: "tab-\(UUID().uuidString)")
        return (model, backend)
    }

    @Test func aNewTabCreatesItsConversationAndStreamsTheReply() async throws {
        guard let daemon = try Daemon.start() else { return }
        defer { daemon.stop() }
        let (model, backend) = makeModel(daemon)
        await model.start()
        try await eventually("connected") { if case .connected = model.connection { return true }; return false }
        let id = model.send(text: "hi")
        #expect(delivery(model, id) == .sending, "the message shows before the backend answers")
        try await eventually("the reply") { text(model).contains("A:echo: hi") }
        #expect(model.conversationID != nil)
        #expect(delivery(model, id) == .delivered)
        #expect(text(model).filter { $0 == "U:hi" }.count == 1)
        await model.stop()
        await backend.shutdown()
    }

    @Test func queuedMessagesKeepOrderAndOneCanBeRemoved() async throws {
        guard let daemon = try Daemon.start() else { return }
        defer { daemon.stop() }
        let (model, backend) = makeModel(daemon)
        await model.start()
        try await eventually("connected") { if case .connected = model.connection { return true }; return false }
        model.send(text: "slow")
        try await eventually("conversation") { model.conversationID != nil && model.state.status == .running }
        let a = model.send(text: "a")
        let b = model.send(text: "b")
        let c = model.send(text: "c")
        try await eventually("queued") { delivery(model, c) == .queued(position: 3) }
        try await model.dequeue(b)
        try await eventually("renumbered") { delivery(model, c) == .queued(position: 2) && delivery(model, b) == nil }
        try await eventually("all ran") { text(model).contains("A:echo: c") }
        let users = text(model).filter { $0.hasPrefix("U:") }
        #expect(users == ["U:slow", "U:a", "U:c"])
        #expect(delivery(model, a) == .delivered)
        await model.stop()
        await backend.shutdown()
    }

    @Test func anAttachedFileUploadsAndReachesTheAgent() async throws {
        guard let daemon = try Daemon.start() else { return }
        defer { daemon.stop() }
        let (model, backend) = makeModel(daemon)
        await model.start()
        try await eventually("connected") { if case .connected = model.connection { return true }; return false }
        let bytes = Data((0..<700_000).map { UInt8($0 % 251) })
        let file = daemon.home.appendingPathComponent("report.pdf")
        try bytes.write(to: file)
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let attachment = OutgoingAttachment(uploadID: "u-\(UUID().uuidString.prefix(8))", fileURL: file, name: "report.pdf", mimeType: "application/pdf", size: UInt64(bytes.count), sha256: sha)
        model.send(text: "blocks", attachments: [attachment])
        try await eventually("uploaded") { model.state.attachments[attachment.uploadID]?.state == .uploaded }
        try await eventually("agent saw the file") { text(model).contains { $0.contains("resource_link") && $0.contains("report.pdf") } }
        await model.stop()
        await backend.shutdown()
    }

    @Test func historyLoadsNewestFirstThenOlderPages() async throws {
        guard let daemon = try Daemon.start() else { return }
        defer { daemon.stop() }
        let (writer, backend) = makeModel(daemon)
        await writer.start()
        try await eventually("connected") { if case .connected = writer.connection { return true }; return false }
        for i in 0..<6 { writer.send(text: "m\(i)") }
        try await eventually("all replies") { text(writer).contains("A:echo: m5") }
        let id = try #require(writer.conversationID)
        await writer.stop()

        let socket = daemon.socket
        let reader = ConversationModel(backend: AcpmuxBackend(opener: UnixSocketStreamOpener { socket }, clientName: "reader", singleAttachment: true), conversationID: id, outbox: FileOutboxStore(directory: daemon.home.appendingPathComponent("o2")), outboxKey: "r", pageSize: 8)
        await reader.start()
        try await eventually("newest page") { text(reader).contains("A:echo: m5") }
        #expect(reader.state.hasOlder)
        #expect(!text(reader).contains("U:m0"))
        while reader.state.hasOlder { await reader.loadOlder() }
        let users = text(reader).filter { $0.hasPrefix("U:") }
        #expect(users == (0..<6).map { "U:m\($0)" })
        await reader.stop()
        await backend.shutdown()
    }
}
