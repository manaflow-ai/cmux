import CmuxNextBrowser
import Foundation
import Network
import Synchronization
import Testing
@testable import CmuxNextRemoteBrowser
import CmuxNextRemoteView

#if DEBUG
/// cx-erey: a remote tab whose host refuses it (no per-launch secret, or a
/// wrong one) or that finds no host stayed blank with no title and no error.
/// The tab now says why, in its page area and its title, and the address
/// form takes the host's secret from a private file (never the record URL).
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct RemoteBrowserFailureTests {
    @Test func aRefusedHelloShowsTheRefusalInTheTab() async throws {
        let host = try await RefusingHost.start()
        defer { host.stop() }
        let tab = try Self.openTab(port: host.port, token: nil)
        try await Self.until { tab.failure != nil }
        #expect(tab.failure == .refused(hadSecret: false))
        #expect(tab.state.title == RemoteBrowserStrings.failureTitle)
        let message = try #require(tab.pane.view.failureMessage)
        #expect(message.contains("127.0.0.1:\(host.port)"))
        #expect(message == RemoteBrowserStrings.failure(.refused(hadSecret: false), address: "127.0.0.1:\(host.port)"))
        tab.close()
    }

    @Test func aRefusedSecretSaysTheSecretDoesNotMatch() async throws {
        let host = try await RefusingHost.start()
        defer { host.stop() }
        let tab = try Self.openTab(port: host.port, token: String(repeating: "a", count: 64))
        try await Self.until { tab.failure != nil }
        #expect(tab.failure == .refused(hadSecret: true))
        tab.close()
    }

    @Test func noHostAtTheAddressShowsUnreachable() async throws {
        let port = try await RefusingHost.freePort()
        let tab = try Self.openTab(port: port, token: nil)
        try await Self.until { tab.failure != nil }
        #expect(tab.failure == .unreachable)
        #expect(tab.pane.view.failureMessage != nil)
        tab.close()
    }

    @Test func closingTheTabIsNoFailure() throws {
        let tab = try Self.openTab(port: 4103, token: nil, start: false)
        tab.close()
        #expect(tab.failure == nil)
        #expect(tab.pane.view.failureMessage == nil)
    }

    @Test func aSecretFileFailureShowsWithoutConnecting() throws {
        let tab = try Self.openTab(port: 4103, token: nil, start: false)
        let session = try #require(RemoteBrowserSession.session(of: tab))
        session.fail(.secretFile(.notPrivate, path: "/tmp/host.secret"))
        #expect(tab.failure == .secretFile(.notPrivate, path: "/tmp/host.secret"))
        #expect(tab.pane.view.failureMessage?.contains("/tmp/host.secret") == true)
        tab.close()
    }

    // MARK: Secret file

    @Test func aPrivateSecretFileGivesItsFirstLine() throws {
        let file = try Self.secretFile("0123abcd\nignored\n", mode: 0o600)
        #expect(try RemoteBrowserSecretFile(path: file.path).read() == "0123abcd")
    }

    @Test func aSecretFileOthersCanReadIsRefused() throws {
        for mode: mode_t in [0o644, 0o640, 0o604] {
            let file = try Self.secretFile("s3cret\n", mode: mode)
            #expect(throws: RemoteBrowserSecretFile.Failure.notPrivate) { try RemoteBrowserSecretFile(path: file.path).read() }
        }
    }

    @Test func aMissingOrEmptySecretFileIsRefused() throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: "cmux-rb-missing-\(UUID().uuidString)")
        #expect(throws: RemoteBrowserSecretFile.Failure.missing) { try RemoteBrowserSecretFile(path: missing.path).read() }
        let empty = try Self.secretFile("\n", mode: 0o600)
        #expect(throws: RemoteBrowserSecretFile.Failure.empty) { try RemoteBrowserSecretFile(path: empty.path).read() }
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-rb-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(throws: RemoteBrowserSecretFile.Failure.notRegularFile) { try RemoteBrowserSecretFile(path: directory.path).read() }
    }

    @Test func theRecordKeepsTheSecretFilePathNeverTheSecret() throws {
        let file = try Self.secretFile("topsecretvalue\n", mode: 0o600)
        let record = try #require(RemoteBrowserTabRecord(address: "127.0.0.1:4103", secretFile: file.path))
        #expect(record.secretFile == file.path)
        #expect(!record.url.absoluteString.contains("topsecretvalue"))
        let again = try #require(RemoteBrowserTabRecord(url: record.url))
        #expect(again == record)
        #expect(RemoteBrowserTabRecord(address: "127.0.0.1:4103", secretFile: "relative/path") == nil, "the path must be absolute")
        #expect(RemoteBrowserTabRecord(address: "4103")?.secretFile == nil)
    }

    // MARK: Fixtures

    private static func openTab(port: UInt16, token: String?, start: Bool = true) throws -> RemoteBrowserTab {
        let endpoint = try #require(RemoteRdLoopbackEndpoint(port: port))
        let tab = try #require(RemoteBrowserSession.makeTab(
            record: RemoteBrowserTabRecord(endpoint: endpoint), id: BrowserTabID.random(), profile: .default, viewer: "test", token: token))
        if start { RemoteBrowserSession.session(of: tab)?.start() }
        return tab
    }

    private static func secretFile(_ text: String, mode: mode_t) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "cmux-rb-secret-\(UUID().uuidString)")
        try Data(text.utf8).write(to: url)
        #expect(chmod(url.path, mode) == 0)
        return url
    }

    private static func until(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() {
            try #require(ContinuousClock.now < deadline, "condition not met within 10 s")
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// A loopback rd host that answers every viewer's first bytes (its hello)
/// with `refused`, as cmux-remote-browser-host does for a viewer without its
/// secret (launch.rs `admit`), then closes.
private nonisolated final class RefusingHost: Sendable {
    let port: UInt16
    private let listener: NWListener

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    static func start() async throws -> RefusingHost {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "test.refusing-host")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { _, _, _, _ in
                guard let json = try? RemoteRdControl.refused(reason: "unauthorized").json(),
                      let frame = try? RemoteRdCore.streamFrame(json, control: true) else { return connection.cancel() }
                connection.send(content: frame, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        let port = try await ready(listener, queue: queue)
        return RefusingHost(listener: listener, port: port)
    }

    /// A loopback port nobody listens on (bound, then released).
    static func freePort() async throws -> UInt16 {
        let host = try await start()
        host.stop()
        return host.port
    }

    func stop() { listener.cancel() }

    private static func ready(_ listener: NWListener, queue: DispatchQueue) async throws -> UInt16 {
        let once = Mutex(false)
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard once.withLock({ done in defer { done = true }; return !done }) else { return }
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case let .failed(error):
                    guard once.withLock({ done in defer { done = true }; return !done }) else { return }
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }
}
#endif
