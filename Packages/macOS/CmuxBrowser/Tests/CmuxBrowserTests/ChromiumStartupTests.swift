import Foundation
import Testing
@testable import CmuxBrowser

@Suite("Chromium startup lifecycle")
struct ChromiumStartupTests {
    @Test("Readiness waits on a stopped session fail promptly", arguments: [false, true])
    func stoppedSessionReadiness(navigation: Bool) async throws {
        let network = URLSession(configuration: .ephemeral)
        defer { network.invalidateAndCancel() }
        let session = ChromiumBrowserSession(
            profileID: UUID(),
            environment: ChromiumBrowserRuntimeEnvironment(
                fileManager: .default,
                runtimeDownloadSession: network,
                loopbackCDPSession: network,
                applicationSupportURLProvider: { nil },
                bundleIdentifierProvider: { "com.cmux.stopped-test" },
                executableOverrideProvider: { nil },
                startupDeadline: {}
            )
        )
        await #expect(throws: CDPError.notConnected) {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    if navigation {
                        try await session.waitForNavigation(to: nil, after: 0)
                    } else {
                        try await session.waitForDocumentReady()
                    }
                }
                group.addTask {
                    try await ContinuousClock().sleep(for: .milliseconds(500))
                    throw ChromiumBrowserDiagnostic.startupTimedOut
                }
                defer { group.cancelAll() }
                try await group.next()
            }
        }
    }

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
