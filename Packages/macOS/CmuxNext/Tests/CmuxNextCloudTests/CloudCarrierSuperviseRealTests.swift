@testable import CmuxNextCloud
import Foundation
import LocalAuthentication
import Security
import Testing

/// The same-tree `cmux-tui` the suite drives, if the runner provides one. Outside the suite: a suite's own
/// static in its `@Suite` trait is a circular macro reference.
enum SuperviseBinary {
    static let url: URL? = {
        let environment = ProcessInfo.processInfo.environment
        for key in ["CMUX_NEXT_TUI_BIN", "CMUX_NEXT_TUI_TREE_PATH"] {
            if let path = environment[key], !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }()

    /// Whether this session can store a key the way the supervisor stores its carrier key (cmux-tui
    /// `carrier/noise_key.rs`: `SecItemAdd` of a generic password in the login Keychain). A headless worker's
    /// session refuses the add (-60008), so the supervisor fails its handshake there whatever the app answers.
    /// The probe adds and deletes a throwaway item of its own, with no UI.
    static let keychainWritable: Bool = {
        let context = LAContext()
        context.interactionNotAllowed = true
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.cmuxterm.app.next.tests.keychain-probe",
            kSecAttrAccount as String: UUID().uuidString,
            kSecAttrSynchronizable as String: false,
            kSecUseAuthenticationContext as String: context,
        ]
        var add = item
        add[kSecValueData as String] = Data(count: 32)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return false }
        SecItemDelete(item as CFDictionary)
        return true
    }()
}

/// ``CloudCarrierServe`` driving the REAL `cmux-tui carrier supervise` (the same-tree build the suite runner
/// fetches, `CMUX_NEXT_TUI_TREE_PATH`, or `CMUX_NEXT_TUI_BIN`), with an environment the way the app builds it:
/// the token read hops to the main actor, and the token is a JWT the size of a real access token. The shell
/// stand-in of ``CloudCarrierServeEdgeTests`` answers its own token reads, so it never showed whether the app's
/// answer reaches the real supervisor (2026-11-15: every Cloud chat start of the NIGHTLY waited 180 s with the
/// supervisor holding its lease and no `carrier serve` child).
@Suite(.enabled(if: SuperviseBinary.url != nil, "needs the same-tree cmux-tui"),
       .enabled(if: SuperviseBinary.keychainWritable, "needs a GUI session: the supervisor keeps its carrier key in the login Keychain"),
       .serialized, .timeLimit(.minutes(2)))
struct CloudCarrierSuperviseRealTests {
    /// A `cmux-link-<12 hex>.sock` in this user's private temporary folder, as ``CloudPaths/linkSocket(machineID:)``.
    static func socket() -> String {
        let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)
        return (NSTemporaryDirectory() as NSString).appendingPathComponent("cmux-link-\(hex).sock")
    }

    /// A JWT-shaped token about as long as a real access token (~1.5 KB), expiring in an hour.
    static func accessToken() -> String {
        let encode = { (data: Data) in
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let exp = Int(Date().timeIntervalSince1970) + 3600
        let header = encode(Data(#"{"alg":"ES256","kid":"test","typ":"JWT"}"#.utf8))
        let claims = #"{"sub":"user_test","exp":\#(exp),"pad":"\#(String(repeating: "p", count: 1100))"}"#
        return "\(header).\(encode(Data(claims.utf8))).\(String(repeating: "s", count: 86))"
    }

    /// The app's connector environment: a main-actor hop (CloudAuth is main-actor), then the dial environment.
    static func connector(machine: String = "vm_0123456789abcdef0123", state: URL,
                          read: @escaping @Sendable () async throws -> Void = {}) throws -> CloudCarrierDial.Connector {
        let cli = try #require(SuperviseBinary.url)
        let token = accessToken()
        return CloudCarrierDial.Connector(cli: cli, dial: try #require(CloudCarrierDial(machine: machine, service: .mux))) {
            let team = await MainActor.run { "team_0123456789abcdef0123" }
            try await read()
            return CloudCarrierDial.environment(platform: URL(string: "http://127.0.0.1:9")!, accessToken: token, team: team,
                                                stateDirectory: state)
        }
    }

    static func stateDirectory() throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ccsr-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return folder
    }

    /// The socket, or why not, within `limit`.
    static func socketPath(_ serve: CloudCarrierServe, keepingRefusal: Bool = false, within limit: Duration = .seconds(20)) async -> Result<String, any Error> {
        await withTaskGroup(of: Result<String, any Error>?.self) { group in
            group.addTask {
                do { return .success(try await serve.socketPath(keepingRefusal: keepingRefusal)) } catch { return .failure(error) }
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .failure(CloudLinkError.disconnected(reason: "no answer within \(limit)"))
        }
    }

    @Test func aConnectGetsTheRealSupervisorsSocket() async throws {
        let state = try Self.stateDirectory()
        defer { try? FileManager.default.removeItem(at: state) }
        let socket = Self.socket()
        let serve = CloudCarrierServe(connector: try Self.connector(state: state), socket: socket)
        let result = await Self.socketPath(serve)
        #expect((try? result.get()) == socket, "\(result)")
        await serve.stop()
    }

    @Test func aConnectFromABackgroundTaskGetsTheSocket() async throws {
        let state = try Self.stateDirectory()
        defer { try? FileManager.default.removeItem(at: state) }
        let socket = Self.socket()
        let serve = CloudCarrierServe(connector: try Self.connector(state: state), socket: socket)
        let result = await Task(priority: .background) { await Self.socketPath(serve) }.value
        #expect((try? result.get()) == socket, "\(result)")
        await serve.stop()
    }

    @Test func twoConnectsAtOnceBothGetTheSocket() async throws {
        let state = try Self.stateDirectory()
        defer { try? FileManager.default.removeItem(at: state) }
        let socket = Self.socket()
        let serve = CloudCarrierServe(connector: try Self.connector(state: state), socket: socket)
        async let first = Self.socketPath(serve)
        async let second = Self.socketPath(serve, keepingRefusal: true)
        let (a, b) = await (first, second)
        #expect((try? a.get()) == socket, "\(a)")
        #expect((try? b.get()) == socket, "\(b)")
        await serve.stop()
    }

    @Test func aSlowTokenReadStillAnswers() async throws {
        let state = try Self.stateDirectory()
        defer { try? FileManager.default.removeItem(at: state) }
        let socket = Self.socket()
        let serve = CloudCarrierServe(connector: try Self.connector(state: state) { try await Task.sleep(for: .seconds(2)) }, socket: socket)
        let result = await Self.socketPath(serve)
        #expect((try? result.get()) == socket, "\(result)")
        await serve.stop()
    }

    @Test func aFailedTokenReadFailsTheConnectAndTheNextConnectsWorks() async throws {
        let state = try Self.stateDirectory()
        defer { try? FileManager.default.removeItem(at: state) }
        let socket = Self.socket()
        let failures = Counter()
        let serve = CloudCarrierServe(connector: try Self.connector(state: state) {
            if await failures.next() == 1 { throw CloudLinkError.helperNotRunning(reason: "signed out") }
        }, socket: socket)
        let failed = await Self.socketPath(serve)
        #expect(throws: (any Error).self, "\(failed)") { try failed.get() }
        let result = await Self.socketPath(serve)
        #expect((try? result.get()) == socket, "\(result)")
        await serve.stop()
    }

    @Test func aParkDuringTheTokenReadThenAConnectGetsTheSocket() async throws {
        let state = try Self.stateDirectory()
        defer { try? FileManager.default.removeItem(at: state) }
        let socket = Self.socket()
        let serve = CloudCarrierServe(connector: try Self.connector(state: state) { try await Task.sleep(for: .milliseconds(500)) }, socket: socket)
        async let parked = Self.socketPath(serve)
        try await Task.sleep(for: .milliseconds(100))
        await serve.park()
        _ = await parked
        let result = await Self.socketPath(serve)
        #expect((try? result.get()) == socket, "\(result)")
        await serve.stop()
    }

    /// A token read that never returns (an auth call that ignores its deadline and its cancellation) is
    /// answered as failed at the edge's deadline, so the real supervisor gives back its lease and the next
    /// connect reads again. Before, the connect and every later one waited forever (2026-11-15).
    @Test func aTokenReadThatNeverReturnsIsAnsweredFailedAndTheNextConnectWorks() async throws {
        let state = try Self.stateDirectory()
        defer { try? FileManager.default.removeItem(at: state) }
        let socket = Self.socket()
        let reads = Counter()
        let stuck = Stuck()
        let serve = CloudCarrierServe(connector: try Self.connector(state: state) {
            if await reads.next() == 1 { await stuck.wait() }
        }, socket: socket, tokenReadDeadline: .seconds(1))
        let failed = await Self.socketPath(serve, within: .seconds(10))
        #expect(throws: CloudLinkError.self, "\(failed)") { try failed.get() }
        let result = await Self.socketPath(serve)
        #expect((try? result.get()) == socket, "\(result)")
        await stuck.release()
        await serve.stop()
    }

    /// A wait that ignores cancellation until ``release()``.
    private actor Stuck {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var released = false
        func wait() async {
            guard !released else { return }
            await withCheckedContinuation { waiting.append($0) }
        }
        func release() {
            released = true
            for waiter in waiting { waiter.resume() }
            waiting = []
        }
    }

    private actor Counter {
        private var count = 0
        func next() -> Int { count += 1; return count }
    }
}
