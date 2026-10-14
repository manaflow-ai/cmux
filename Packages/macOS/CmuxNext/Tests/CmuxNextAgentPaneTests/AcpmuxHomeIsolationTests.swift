import Darwin
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Two builds never share an acpmux daemon (2026-10-14): a tagged DEV app launched from a
/// terminal of cmux NEXT inherited NEXT's `ACPMUX_SOCKET`. It took its home from its tag but
/// its socket from that variable, found NEXT's daemon there, saw another build and handed it
/// off, so NEXT's daemon stopped. An inherited socket without its home is another daemon's.
struct AcpmuxHomeIsolationTests {
    static let user = URL(fileURLWithPath: "/Users/me", isDirectory: true)
    static let nextSocket = "/Users/me/.acpmux/tags/cmux-next/acpmux.sock"

    private static func resolve(tag: String?, _ environment: [String: String]) throws -> AcpmuxEnvironment {
        try #require(AcpmuxEnvironment.resolve(tag: tag, bundledBinDirectory: URL(fileURLWithPath: "/App/bin"),
                                               environment: environment, userHome: user, uid: 501,
                                               isExecutable: { _ in true }))
    }

    @Test func anInheritedSocketWithoutItsHomeIsAnotherDaemons() throws {
        let tagged = try Self.resolve(tag: "cgstrip", ["ACPMUX_SOCKET": Self.nextSocket])
        #expect(tagged.home.path == "/Users/me/.acpmux/tags/cgstrip")
        #expect(tagged.socketPath == "/Users/me/.acpmux/tags/cgstrip/acpmux.sock")
        #expect(tagged.childEnvironment["ACPMUX_SOCKET"] == tagged.socketPath)
        let untagged = try Self.resolve(tag: nil, ["ACPMUX_SOCKET": Self.nextSocket])
        #expect(untagged.socketPath == "/Users/me/.acpmux/acpmux.sock")
    }

    @Test func twoTagsUnderOneInheritedEnvironmentNeverShareASocket() throws {
        let inherited = ["ACPMUX_SOCKET": Self.nextSocket, "PATH": "/usr/bin"]
        let tags = ["cgstrip", "cmux-next", "other"]
        let sockets = try tags.map { try Self.resolve(tag: $0, inherited).socketPath }
        #expect(Set(sockets).count == tags.count, "\(sockets)")
        for (tag, socket) in zip(tags, sockets) {
            #expect(socket.hasPrefix("/Users/me/.acpmux/tags/\(tag)/"), "\(tag): \(socket)")
        }
    }

    @Test func anExplicitHomeAndSocketPairStillWins() throws {
        let pair = try Self.resolve(tag: "t", ["ACPMUX_HOME": "/h", "ACPMUX_SOCKET": "/s.sock"])
        #expect(pair.home.path == "/h")
        #expect(pair.socketPath == "/s.sock")
    }

    /// The shared `resolve` cases (cmux-agent-pane-policy tests/cases/environment.json), which
    /// the Rust policy runs too.
    @Test func resolveMatchesTheSharedCases() throws {
        let cases = try #require(AcpmuxSocketPathParityTests.cases["resolve"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        for row in cases {
            let name = row["name"] as? String ?? "?"
            let executables = Set(row["executables"] as? [String] ?? [])
            let got = AcpmuxEnvironment.resolve(
                tag: row["tag"] as? String,
                bundledBinDirectory: (row["bundled"] as? String).map { URL(fileURLWithPath: $0, isDirectory: true) },
                environment: row["env"] as? [String: String] ?? [:],
                userHome: URL(fileURLWithPath: try #require(row["user_home"] as? String), isDirectory: true),
                uid: UInt32(try #require(row["uid"] as? Int)),
                isExecutable: { executables.contains($0) })
            guard let expect = row["expect"] as? [String: Any] else {
                #expect(got == nil, "\(name)")
                continue
            }
            let environment = try #require(got, "\(name)")
            #expect(environment.executable.path == expect["executable"] as? String, "\(name)")
            #expect(environment.home.path == expect["home"] as? String, "\(name)")
            #expect(environment.socketPath == expect["socket"] as? String, "\(name)")
            #expect(environment.daemonArguments == expect["args"] as? [String], "\(name)")
        }
    }
}

/// The handoff that replaces an outdated daemon (``AcpmuxVersionHandoff``, ``AcpmuxPersonKey``)
/// is for this app's own daemon. Here B's socket is A's while their homes differ, and A's
/// executable is gone, which hands off a daemon of B's own home. B must not stop A.
@Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: SameTreeAcpmuxBinary.url != nil, "needs the same-tree acpmux"))
struct AcpmuxOtherHomeDaemonTests {
    @Test func aLaunchNeverStopsAnotherHomesDaemon() async throws {
        let binary = try #require(SameTreeAcpmuxBinary.url)
        let root = URL(fileURLWithPath: "/tmp/aoh-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let binA = root.appendingPathComponent("a/bin", isDirectory: true)
        let binB = root.appendingPathComponent("b/bin", isDirectory: true)
        let homeA = root.appendingPathComponent("homeA", isDirectory: true)
        let homeB = root.appendingPathComponent("homeB", isDirectory: true)
        let socket = homeA.appendingPathComponent("s.sock").path
        for directory in [binA, binB, homeA, homeB] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: binary, to: binA.appendingPathComponent("acpmux"))
        try FileManager.default.copyItem(at: binary, to: binB.appendingPathComponent("acpmux"))
        let a = try #require(AcpmuxEnvironment.resolve(tag: nil, bundledBinDirectory: binA,
                                                       environment: ["ACPMUX_HOME": homeA.path, "ACPMUX_SOCKET": socket]))
        let b = try #require(AcpmuxEnvironment.resolve(tag: nil, bundledBinDirectory: binB,
                                                       environment: ["ACPMUX_HOME": homeB.path, "ACPMUX_SOCKET": socket]))

        var started: Int32?
        var bUsedIt = false
        do {
            try await AcpmuxHost(environment: a).prewarm()
            started = try await AcpmuxStatusClient.status(socketPath: socket, deadline: .seconds(15)).pid
            try FileManager.default.removeItem(at: binA.appendingPathComponent("acpmux"))
            bUsedIt = (try? await AcpmuxHost(environment: b).prewarm()) != nil
        } catch {
            Issue.record("daemon A did not start: \(error)")
        }
        let after = try? await AcpmuxStatusClient.status(socketPath: socket, deadline: .seconds(15))
        // Whatever failed, every daemon this test started ends with it, whichever home it has.
        _ = try? await AcpmuxStatusClient.call(socketPath: socket, method: "_acpmux/shutdown", deadline: .seconds(10))
        let pid = try #require(started)
        #expect(after?.pid == pid, "B stopped A's daemon (now \(String(describing: after?.pid)))")
        #expect(!bUsedIt, "B took a daemon of another home as its own")
    }
}
