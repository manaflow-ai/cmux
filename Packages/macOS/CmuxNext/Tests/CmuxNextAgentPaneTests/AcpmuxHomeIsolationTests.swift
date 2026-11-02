import Darwin
import Foundation
import CmuxNextCompat
import Testing
@testable import CmuxNextAgentPane

/// Two builds never share an acpmux daemon (2026-10-14): a tagged DEV app launched from a
/// terminal of cmux NEXT inherited NEXT's `ACPMUX_SOCKET`. It took its home from its tag but
/// its socket from that variable, found NEXT's daemon there, saw another build and handed it
/// off, so NEXT's daemon stopped. An inherited socket without its home is another daemon's.
struct AcpmuxHomeIsolationTests {
    static let user = URL(fileURLWithPath: "/Users/me", isDirectory: true)
    /// cmux NEXT's daemon socket, as its terminals export it.
    static let nextSocket = "/Users/me/.acpmux/acpmux.sock"

    /// A tagged DEV build's identity.
    static func build(_ tag: String) -> BuildIdentity {
        BuildIdentity(bundleID: "com.cmuxterm.app.debug.\(tag)", bundledTag: tag)
    }

    private static func resolve(tag: String?, _ environment: [String: String]) throws -> AcpmuxEnvironment {
        try #require(AcpmuxEnvironment.resolve(build: tag.map(Self.build), bundledBinDirectory: URL(fileURLWithPath: "/App/bin"),
                                               environment: environment, userHome: user, uid: 501,
                                               isExecutable: { _ in true }, executableOverride: nil))
    }

    @Test func anInheritedSocketWithoutItsHomeIsAnotherDaemons() throws {
        let tagged = try Self.resolve(tag: "cgstrip", ["ACPMUX_SOCKET": Self.nextSocket])
        let home = Self.build("cgstrip").acpmuxHome(userHome: Self.user)
        #expect(tagged.home.path == home.path)
        #expect(tagged.socketPath == home.appendingPathComponent("acpmux.sock").path)
        #expect(tagged.childEnvironment["ACPMUX_SOCKET"] == tagged.socketPath)
        let untagged = try Self.resolve(tag: nil, ["ACPMUX_SOCKET": "/tmp/elsewhere/acpmux.sock"])
        #expect(untagged.socketPath == "/Users/me/.acpmux/acpmux.sock")
    }

    @Test func twoTagsUnderOneInheritedEnvironmentNeverShareASocket() throws {
        let inherited = ["ACPMUX_SOCKET": Self.nextSocket, "PATH": "/usr/bin"]
        let tags = ["cgstrip", "cmux-next", "other"]
        let sockets = try tags.map { try Self.resolve(tag: $0, inherited).socketPath }
        #expect(Set(sockets).count == tags.count, "\(sockets)")
        for (tag, socket) in zip(tags, sockets) {
            #expect(socket.hasPrefix(Self.build(tag).acpmuxHome(userHome: Self.user).path + "/"), "\(tag): \(socket)")
        }
    }

    @Test func anExplicitHomeAndSocketPairStillWins() throws {
        let pair = try Self.resolve(tag: "t", ["ACPMUX_HOME": "/h", "ACPMUX_SOCKET": "/s.sock"])
        #expect(pair.home.path == "/h")
        #expect(pair.socketPath == "/s.sock")
    }

    @Test func aDaemonOfAnotherHomeIsNotThisAppsDaemon() throws {
        let home = URL(fileURLWithPath: "/Users/me/.acpmux/builds/com.cmuxterm.app.debug.cgstrip", isDirectory: true)
        #expect(!AcpmuxStatus(["home": "/Users/me/.acpmux", "build": "x"]).serves(home: home))
        #expect(AcpmuxStatus(["home": "/Users/me/.acpmux/builds/com.cmuxterm.app.debug.cgstrip/"]).serves(home: home))
        #expect(AcpmuxStatus(["home": "/Users/me/.acpmux/builds/../builds/com.cmuxterm.app.debug.cgstrip"]).serves(home: home))
        // A daemon that does not report its home is taken at its socket's word.
        #expect(AcpmuxStatus([:]).serves(home: home))
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
                build: (row["bundle_id"] as? String).map { BuildIdentity(bundleID: $0, bundledTag: row["bundled_tag"] as? String) },
                bundledBinDirectory: (row["bundled"] as? String).map { URL(fileURLWithPath: $0, isDirectory: true) },
                environment: row["env"] as? [String: String] ?? [:],
                userHome: URL(fileURLWithPath: try #require(row["user_home"] as? String), isDirectory: true),
                uid: UInt32(try #require(row["uid"] as? Int)),
                isExecutable: { executables.contains($0) }, executableOverride: nil)
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
        let a = try #require(AcpmuxEnvironment.resolve(build: nil, bundledBinDirectory: binA,
                                                       environment: ["ACPMUX_HOME": homeA.path, "ACPMUX_SOCKET": socket], executableOverride: nil))
        let b = try #require(AcpmuxEnvironment.resolve(build: nil, bundledBinDirectory: binB,
                                                       environment: ["ACPMUX_HOME": homeB.path, "ACPMUX_SOCKET": socket], executableOverride: nil))

        var started: Int32?
        var bUsedIt = false
        do {
            try await AcpmuxHost(daemons: AcpmuxLocalDaemons(), environment: a).prewarm()
            started = try await AcpmuxStatusClient.status(socketPath: socket, deadline: .seconds(15)).pid
            try FileManager.default.removeItem(at: binA.appendingPathComponent("acpmux"))
            bUsedIt = (try? await AcpmuxHost(daemons: AcpmuxLocalDaemons(), environment: b).prewarm()) != nil
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

    /// Every handoff and Quit Everything stop a daemon through `shutdown`, which checks its home.
    @Test func aShutdownNeverStopsAnotherHomesDaemon() async throws {
        let binary = try #require(SameTreeAcpmuxBinary.url)
        let root = URL(fileURLWithPath: "/tmp/aoh-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let other = root.appendingPathComponent("other", isDirectory: true)
        let socket = home.appendingPathComponent("s.sock").path
        for directory in [bin, home, other] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: binary, to: bin.appendingPathComponent("acpmux"))
        let environment = try #require(AcpmuxEnvironment.resolve(build: nil, bundledBinDirectory: bin,
                                                                 environment: ["ACPMUX_HOME": home.path, "ACPMUX_SOCKET": socket], executableOverride: nil))
        var refused: (any Error)?
        var started: Int32?
        do {
            try await AcpmuxHost(daemons: AcpmuxLocalDaemons(), environment: environment).prewarm()
            started = try await AcpmuxStatusClient.status(socketPath: socket, deadline: .seconds(15)).pid
            do {
                try await AcpmuxStatusClient.shutdown(socketPath: socket, home: other, deadline: .seconds(10))
            } catch {
                refused = error
            }
        } catch {
            Issue.record("the daemon did not start: \(error)")
        }
        let after = try? await AcpmuxStatusClient.status(socketPath: socket, deadline: .seconds(15))
        // Its own home stops it.
        try? await AcpmuxStatusClient.shutdown(socketPath: socket, home: home, deadline: .seconds(10))
        let pid = try #require(started)
        let exitDeadline = ContinuousClock.now + .seconds(10)
        while kill(pid, 0) == 0, ContinuousClock.now < exitDeadline { try await Task.sleep(for: .milliseconds(50)) }
        let stoppedByItsHome = kill(pid, 0) != 0
        // Whatever failed, the daemon ends with the test.
        if !stoppedByItsHome {
            _ = try? await AcpmuxStatusClient.call(socketPath: socket, method: "_acpmux/shutdown", deadline: .seconds(10))
        }
        #expect(after?.pid == pid, "a shutdown for another home stopped the daemon")
        if case AcpmuxStatusClient.Failure.otherHome(_)? = refused as? AcpmuxStatusClient.Failure {} else {
            Issue.record("expected .otherHome, got \(String(describing: refused))")
        }
        #expect(stoppedByItsHome, "its own home's shutdown did not stop it")
    }
}
