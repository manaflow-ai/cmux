@testable import CmuxNextCloud
import Foundation
import Testing

/// ``CloudCarrierServe`` driving the REAL `cmux-tui carrier supervise` (the same-tree build the suite runner
/// fetches, `CMUX_NEXT_TUI_TREE_PATH`, or `CMUX_NEXT_TUI_BIN`), with an environment the way the app builds it:
/// the token read hops to the main actor, and the token is a JWT the size of a real access token. The shell
/// stand-in of ``CloudCarrierServeEdgeTests`` answers its own token reads, so it never showed whether the app's
/// answer reaches the real supervisor (2026-11-15: every Cloud chat start of the NIGHTLY waited 180 s with the
/// supervisor holding its lease and no `carrier serve` child).
@Suite(.enabled(if: CloudCarrierSuperviseRealTests.binary != nil, "needs the same-tree cmux-tui"), .serialized, .timeLimit(.minutes(2)))
struct CloudCarrierSuperviseRealTests {
    static let binary: URL? = {
        let environment = ProcessInfo.processInfo.environment
        for key in ["CMUX_NEXT_TUI_BIN", "CMUX_NEXT_TUI_TREE_PATH"] {
            if let path = environment[key], !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }()

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
        let cli = try #require(binary)
        let token = accessToken()
        return CloudCarrierDial.Connector(cli: cli, dial: try #require(CloudCarrierDial(machine: machine, service: .mux))) {
            let team = await MainActor.run { "team_test" }
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

    private actor Counter {
        private var count = 0
        func next() -> Int { count += 1; return count }
    }
}
