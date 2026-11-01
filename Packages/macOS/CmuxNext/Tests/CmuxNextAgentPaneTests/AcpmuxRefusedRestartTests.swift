import Darwin
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A daemon another binary runs on this app's acpmux socket (2026-10-22: a NIGHTLY's shared
/// `~/.acpmux` held by another install's acpmux) left the chat stuck: Retry asked the same daemon
/// again forever. The refusal offers Restart acpmux, and that restart replaces the daemon with
/// this app's own, keeping its sessions.
@Suite(.serialized)
@MainActor
struct AcpmuxRefusedRestartTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// A host whose every handshake is refused with `error`, and that records each restart it is asked for.
    private actor RefusingHost: AgentPaneHostProviding {
        let error: AgentPaneHostError
        private(set) var restarts: [AcpmuxSocketOwner] = []

        init(_ error: AgentPaneHostError) { self.error = error }

        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw error }

        func restartAcpmux(owner: AcpmuxSocketOwner) async -> Bool {
            restarts.append(owner)
            return false
        }
    }

    /// This test process's binary: the fake daemon's peer.
    private var ownPath: String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        _ = proc_pidpath(getpid(), &buffer, UInt32(buffer.count))
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
    }

    /// The page learns it may offer Restart acpmux; the offer names the daemon on that very socket.
    @Test func aRefusedHandshakeOffersRestartAcpmux() async throws {
        try await withFakeDaemon { environment, _ in
            let model = AgentPaneModel(host: AcpmuxHost(daemons: AcpmuxLocalDaemons(), environment: environment))
            let reply = await model.respond(to: .reconnect)
            let error = try #require(reply["error"] as? [String: Any], "the daemon was accepted")
            let details = error["details"] as? [String: Any]
            #expect(details?["restartAcpmux"] as? Bool == true, "the refusal offers no restart: \(error)")
            #expect(model.acpmuxRestartOffered == AcpmuxSocketOwner(path: ownPath, socketPath: environment.socketPath))
        }
    }

    /// A daemon's start or restart ends without the person, so the page shows nothing while it
    /// lasts; acpmux missing and another build's daemon do not, and are said at once.
    @Test func onlyARecoveryIsAReconnectingHandshake() async throws {
        let recovering: [AgentPaneHostError] = [
            .daemonRestarting, .timedOut, .daemonStopped, .chiefStopped, .chiefStarting,
            .daemonFailed(logPath: "/l", cause: .exited),
            .daemonRefused(holder: nil, socketPath: "/s", reason: "the socket's peer process is unknown"),
        ]
        let refused: [AgentPaneHostError] = [
            .acpmuxNotFound,
            .daemonRefused(holder: "cmux NIGHTLY", socketPath: "/s", reason: "another build"),
            .daemonFailed(logPath: "/l", cause: .refused("a temporary folder")),
        ]
        for cause in recovering + refused {
            let model = AgentPaneModel(host: RefusingHost(cause))
            let reply = await model.respond(to: .reconnect)
            let error = try #require(reply["error"] as? [String: Any])
            let details = error["details"] as? [String: Any]
            #expect((details?["reconnecting"] as? Bool == true) == recovering.contains(cause), "\(cause)")
        }
    }

    /// Without a refusal that offered it, or without the person's click, the page cannot stop a daemon.
    @Test func restartAcpmuxNeedsAnOfferAndAGesture() async {
        let model = AgentPaneModel(host: NoHost())
        model.transport.gestures.record(click: true)
        let unoffered = await model.respond(to: AgentPaneRequest(body: ["method": "acpmux.restart", "params": [:]]))
        #expect(unoffered["ok"] as? Bool == false)
        let ungestured = await model.respond(to: AgentPaneRequest(body: ["method": "acpmux.restart", "params": [:]]))
        #expect((ungestured["error"] as? [String: Any])?["code"] as? String == "acpmux.gesture_required")
    }

    /// A daemon without agent hosts would end its agents with it: Restart acpmux keeps it running.
    @Test func restartAcpmuxNeverStopsADaemonWithoutAgentHosts() async throws {
        try await withFakeDaemon(agentHosts: false) { environment, daemon in
            let owner = AcpmuxSocketOwner(path: ownPath, socketPath: environment.socketPath)
            #expect(await AcpmuxSocketOwner.takeOver(environment: environment, owner: owner, daemons: AcpmuxLocalDaemons()) == false)
            #expect(!daemon.calls.joined().contains("_acpmux/shutdown"))
        }
    }

    /// Restart acpmux stops only the binary the refusal named: a daemon of another binary that
    /// took the socket since keeps running.
    @Test func restartAcpmuxNeverStopsADaemonTheRefusalDidNotName() async throws {
        try await withFakeDaemon { environment, daemon in
            let owner = AcpmuxSocketOwner(path: "/elsewhere/acpmux", socketPath: environment.socketPath)
            #expect(await AcpmuxSocketOwner.takeOver(environment: environment, owner: owner, daemons: AcpmuxLocalDaemons()) == false)
            #expect(!daemon.calls.joined().contains("_acpmux/shutdown"))
        }
    }

    /// The owner the refusal read on one socket never stops the daemon on another (Codex review of
    /// #24420: a Chief home's refusal named a binary, and the restart went to this Mac's socket,
    /// where the same binary could run an unrelated daemon). Nothing is even sent to that daemon.
    @Test func restartAcpmuxNeverStopsADaemonOnAnotherSocket() async throws {
        try await withFakeDaemon { environment, daemon in
            let owner = AcpmuxSocketOwner(path: ownPath, socketPath: environment.socketPath + ".chief")
            let stopped = await AcpmuxSocketOwner.takeOver(environment: environment, owner: owner, daemons: AcpmuxLocalDaemons(),
                                                           bootOut: { _, _ in false }, exited: { _ in true })
            #expect(!stopped)
            let restarted = await AcpmuxHost(daemons: AcpmuxLocalDaemons(), environment: environment).restartAcpmux(owner: owner)
            #expect(!restarted)
            let asked = daemon.calls.contains { !$0.isEmpty }
            #expect(!asked, "a daemon on another socket was asked: \(daemon.calls)")
        }
    }

    /// The owner the refusal read on this socket is the one Restart acpmux stops: one connection,
    /// its status, then its shutdown (launchd and the exit wait are stubbed: the fake daemon is
    /// this test process).
    @Test func restartAcpmuxStopsTheNamedDaemonOnItsOwnSocket() async throws {
        try await withFakeDaemon { environment, daemon in
            let owner = AcpmuxSocketOwner(path: ownPath, socketPath: environment.socketPath)
            let stopped = await AcpmuxSocketOwner.takeOver(environment: environment, owner: owner, daemons: AcpmuxLocalDaemons(),
                                                           bootOut: { _, _ in false }, exited: { _ in true })
            #expect(stopped)
            #expect(daemon.calls.contains(["initialize", "_acpmux/status", "_acpmux/shutdown"]), "\(daemon.calls)")
        }
    }

    /// A second Restart acpmux while the first one stops that daemon asks it nothing: the claim is
    /// the app's one ``AcpmuxLocalDaemons``, which every host gets, and it ends with that restart.
    @Test func aSecondRestartWhileTheFirstRunsAsksNothing() async throws {
        try await withFakeDaemon { environment, daemon in
            let daemons = AcpmuxLocalDaemons()
            let owner = AcpmuxSocketOwner(path: ownPath, socketPath: environment.socketPath)
            // The fake daemon is this test process: the first restart holds its pid.
            #expect(daemons.claimStop(getpid()))
            let stopped = await AcpmuxSocketOwner.takeOver(environment: environment, owner: owner, daemons: daemons,
                                                           bootOut: { _, _ in false }, exited: { _ in true })
            #expect(!stopped)
            #expect(!daemon.calls.contains { !$0.isEmpty }, "the daemon was asked: \(daemon.calls)")
            daemons.endStop(getpid())
            #expect(daemons.claimStop(getpid()), "the claim ends with the restart that made it")
        }
    }

    /// A chat the Chief home's acpmux runs offers no Restart acpmux: that replaces only this Mac's
    /// own daemon. A chat on this Mac's acpmux keeps its offer.
    @Test func aChiefRefusalOffersNoRestart() async throws {
        let owner = AcpmuxSocketOwner(path: "/other/acpmux", socketPath: "/h/chief.sock")
        let refusal = AgentPaneHostError.daemonRefused(holder: nil, socketPath: "/h/chief.sock", reason: "r",
                                                       executable: "/app/acpmux", owner: owner)
        let local = RefusingHost(.daemonRefused(holder: nil, socketPath: "/h/local.sock", reason: "r",
                                                executable: "/app/acpmux",
                                                owner: AcpmuxSocketOwner(path: "/other/acpmux", socketPath: "/h/local.sock")))
        let router = AcpmuxChiefSessionRouter(local: local, chief: RefusingHost(refusal)) { $0 == "chief-session" }
        let asks: [@Sendable () async throws -> AgentPaneHandshake] = [
            { try await router.handshake(sessionId: "chief-session") },
            { try await router.reconnectHandshake(sessionId: "chief-session") },
        ]
        for ask in asks {
            do {
                _ = try await ask()
                Issue.record("the Chief's refusal was accepted")
            } catch let error as AgentPaneHostError {
                guard case .daemonRefused(_, let socketPath, _, _, let offered) = error else {
                    Issue.record("expected daemonRefused, got \(error)")
                    continue
                }
                #expect(socketPath == "/h/chief.sock")
                #expect(offered == nil, "a Chief refusal offers Restart acpmux")
            }
        }
        do {
            _ = try await router.handshake(sessionId: "local-session")
            Issue.record("the local refusal was accepted")
        } catch AgentPaneHostError.daemonRefused(_, _, _, _, let offered) {
            #expect(offered?.socketPath == "/h/local.sock")
        }
    }

    private func withFakeDaemon<T>(agentHosts: Bool = true, _ body: (AcpmuxEnvironment, FakeDaemon) async throws -> T) async throws -> T {
        let (root, environment, server) = try fakeDaemonEnvironment(agentHosts: agentHosts)
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: root)
        }
        return try await body(environment, server)
    }

    private func fakeDaemonEnvironment(agentHosts: Bool = true) throws -> (URL, AcpmuxEnvironment, FakeDaemon) {
        let root = URL(fileURLWithPath: "/tmp/arr-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let acpmux = bin.appendingPathComponent("acpmux")
        try "#!/bin/sh\nexit 1\n".write(to: acpmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: acpmux.path)
        let socketPath = home.appendingPathComponent("s.sock").path
        let environment = try #require(AcpmuxEnvironment.resolve(
            build: nil, bundledBinDirectory: bin, environment: ["ACPMUX_HOME": home.path, "ACPMUX_SOCKET": socketPath],
            executableOverride: nil))
        return (root, environment, try FakeDaemon(socketPath: socketPath, agentHosts: agentHosts))
    }
}

/// The person's Restart acpmux, end to end with real daemons: another binary's acpmux (inside
/// another app bundle) holds the home. Base accepts such a daemon when it supports the person
/// challenge, so no handshake refuses it here; the refusal's offer is set as a refusal sets it (the
/// offer itself is covered above). Restart acpmux stops it, and the next handshake runs this app's own.
@Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: SameTreeAcpmuxBinary.url != nil, "needs the same-tree acpmux"))
@MainActor
struct AcpmuxRefusedRestartDaemonTests {
    @Test func restartAcpmuxReplacesAnotherBinarysDaemon() async throws {
        let binary = try #require(SameTreeAcpmuxBinary.url)
        let root = URL(fileURLWithPath: "/tmp/arrd-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let bin = root.appendingPathComponent("app/bin", isDirectory: true)
        let otherBin = root.appendingPathComponent("Other.app/Contents/Resources/bin", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let socket = home.appendingPathComponent("s.sock").path
        for directory in [bin, otherBin, home] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: binary, to: bin.appendingPathComponent("acpmux"))
        try FileManager.default.copyItem(at: binary, to: otherBin.appendingPathComponent("acpmux"))
        func environment(_ directory: URL) throws -> AcpmuxEnvironment {
            try #require(AcpmuxEnvironment.resolve(build: nil, bundledBinDirectory: directory,
                                                   environment: ["ACPMUX_HOME": home.path, "ACPMUX_SOCKET": socket],
                                                   executableOverride: nil))
        }
        let outcome: Result<Int32, any Error>
        do { outcome = .success(try await restart(otherBin: otherBin, bin: bin, socket: socket, environment: environment)) } catch { outcome = .failure(error) }
        // Whatever failed, every daemon this test started ends with it.
        let last = try? await AcpmuxStatusClient.status(socketPath: socket, deadline: .seconds(5)).pid
        _ = try? await AcpmuxStatusClient.shutdown(socketPath: socket, home: home, deadline: .seconds(10))
        if let last { #expect(await AgentPaneProcessExit(pid: last).event(within: .seconds(10)), "the daemon outlived its shutdown") }
        _ = try outcome.get()
    }

    /// Another binary's daemon, the offer a refusal leaves, Restart acpmux, and the reconnect; the daemon that runs after.
    private func restart(otherBin: URL, bin: URL, socket: String,
                         environment: (URL) throws -> AcpmuxEnvironment) async throws -> Int32 {
        try await AcpmuxHost(daemons: AcpmuxLocalDaemons(), environment: try environment(otherBin)).prewarm()
        let before = try #require(try await AcpmuxStatusClient.status(socketPath: socket, deadline: .seconds(15)).pid)

        let model = AgentPaneModel(host: AcpmuxHost(daemons: AcpmuxLocalDaemons(), environment: try environment(bin)))
        let owner = try #require(AcpmuxSocketOwner.read(socketPath: socket))
        #expect(owner.path == otherBin.appendingPathComponent("acpmux").resolvingSymlinksInPath().path)
        model.acpmuxRestartOffered = owner

        model.transport.gestures.record(click: true)
        let restart = await model.respond(to: AgentPaneRequest(body: ["method": "acpmux.restart", "params": [:]]))
        #expect((restart["value"] as? [String: Any])?["stopped"] as? Bool == true, "Restart acpmux did not stop it: \(restart)")
        #expect(await AgentPaneProcessExit(pid: before).event(within: .seconds(10)), "the other daemon still runs")

        let connected = await model.respond(to: .ready)
        #expect(connected["ok"] as? Bool == true, "the chat did not connect after the restart: \(connected)")
        let after = try #require(try await AcpmuxStatusClient.status(socketPath: socket, deadline: .seconds(15)).pid)
        #expect(after != before)
        let path = try #require(AcpmuxVersionHandoff.executablePath(pid: after))
        #expect(URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                == bin.appendingPathComponent("acpmux").resolvingSymlinksInPath().path)
        return after
    }
}
