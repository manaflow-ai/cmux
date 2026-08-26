import Foundation
import Testing
@testable import CmuxBrowser

@Suite("Chromium startup lifecycle")
struct ChromiumStartupTests {
    @Test("Peer-ended CDP streams still close their transport")
    func peerEndedTransportCleanup() async throws {
        let transport = PeerEndingCDPTransport()
        let connection = ChromiumCDPConnection(transport: transport)
        try await connection.connect()
        let events = await connection.events()
        let streamEnded = Task {
            for await _ in events {}
        }

        await transport.finishFromPeer()
        await streamEnded.value
        await connection.shutdown()

        let closeCount = await transport.closeCountValue()
        #expect(closeCount == 1)
    }

    @Test("A stalled CDP command fails at the connection deadline")
    func stalledCommandDeadline() async throws {
        let transport = RecordingCDPTransport()
        let connection = ChromiumCDPConnection(
            transport: transport,
            commandTimeout: .milliseconds(10)
        )
        try await connection.connect()

        await #expect(throws: ChromiumBrowserDiagnostic.commandTimedOut) {
            _ = try await connection.send(method: "Runtime.evaluate")
        }
        await connection.shutdown()
    }

    @Test("A launched child has a deterministic CDP handshake deadline")
    func startupHandshakeDeadline() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-chromium-startup-test-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("blocking-headless-shell")
        let script = "#!/bin/sh\nexec /bin/cat <&3 >/dev/null\n"
        try Data(script.utf8).write(to: executable)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let downloadSession = URLSession(configuration: .ephemeral)
        let loopbackSession = URLSession(configuration: .ephemeral)
        let environment = ChromiumBrowserRuntimeEnvironment(
            fileManager: fileManager,
            runtimeDownloadSession: downloadSession,
            loopbackCDPSession: loopbackSession,
            applicationSupportURLProvider: { root },
            bundleIdentifierProvider: { "com.example.cmux-startup-test" },
            executableOverrideProvider: { executable },
            startupDeadline: {}
        )
        let session = ChromiumBrowserSession(
            profileID: UUID(),
            environment: environment
        )

        await #expect(throws: ChromiumBrowserDiagnostic.startupTimedOut) {
            try await session.start()
        }
        await session.stopAndWait()
        downloadSession.invalidateAndCancel()
        loopbackSession.invalidateAndCancel()
        try fileManager.removeItem(at: root)
    }
}

private actor PeerEndingCDPTransport: ChromiumCDPTransport {
    private let stream: AsyncStream<Result<Data, CDPError>>
    private let continuation: AsyncStream<Result<Data, CDPError>>.Continuation
    private var closeCount = 0

    init() {
        let pair = AsyncStream<Result<Data, CDPError>>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func connect() async throws {}

    nonisolated func messages() -> AsyncStream<Result<Data, CDPError>> {
        stream
    }

    func send(_ data: Data) async throws {}

    func close() {
        closeCount += 1
        continuation.finish()
    }

    func finishFromPeer() {
        continuation.finish()
    }

    func closeCountValue() -> Int {
        closeCount
    }
}

@Suite("Chromium screencast fast path")
struct ChromiumScreencastFastPathTests {
    @Test("Screencast frames bypass generic events, decode, and ack immediately")
    func screencastFramesAreFastPathed() async throws {
        let transport = RecordingCDPTransport()
        let connection = ChromiumCDPConnection(transport: transport)
        try await connection.connect()
        let frames = await connection.screencastFrames()
        let events = await connection.events()

        let receivedFrame = Task { await frames.first(where: { _ in true }) }
        let receivedEvents = Task { () -> [String] in
            var methods: [String] = []
            for await event in events { methods.append(event.method) }
            return methods
        }

        let payload = Data("frame-bytes".utf8)
        let envelope: [String: Any] = [
            "method": "Page.screencastFrame",
            "params": [
                "data": payload.base64EncodedString(),
                "sessionId": 7,
                "metadata": ["timestamp": 1.0],
            ],
        ]
        await transport.emit(try JSONSerialization.data(withJSONObject: envelope))
        // A non-frame event must still travel the generic event path.
        await transport.emit(Data(#"{"method":"Page.loadEventFired","params":{}}"#.utf8))

        #expect(await receivedFrame.value == payload)
        let ack = try #require(await transport.firstSentMessage())
        let ackObject = try #require(
            try JSONSerialization.jsonObject(with: ack) as? [String: Any]
        )
        #expect(ackObject["method"] as? String == "Page.screencastFrameAck")
        #expect((ackObject["params"] as? [String: Any])?["sessionId"] as? Double == 7)

        await transport.finishFromPeer()
        #expect(await receivedEvents.value == ["Page.loadEventFired"])
        await connection.shutdown()
    }
}

private actor RecordingCDPTransport: ChromiumCDPTransport {
    private let stream: AsyncStream<Result<Data, CDPError>>
    private let continuation: AsyncStream<Result<Data, CDPError>>.Continuation
    private var sent: [Data] = []
    private var sentWaiters: [CheckedContinuation<Data, Never>] = []

    init() {
        let pair = AsyncStream<Result<Data, CDPError>>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func connect() async throws {}

    nonisolated func messages() -> AsyncStream<Result<Data, CDPError>> {
        stream
    }

    func send(_ data: Data) async throws {
        sent.append(data)
        let waiters = sentWaiters
        sentWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: data) }
    }

    func close() {
        continuation.finish()
    }

    func emit(_ data: Data) {
        continuation.yield(.success(data))
    }

    func finishFromPeer() {
        continuation.finish()
    }

    func firstSentMessage() async -> Data? {
        if let first = sent.first { return first }
        return await withCheckedContinuation { continuation in
            sentWaiters.append(continuation)
        }
    }
}
