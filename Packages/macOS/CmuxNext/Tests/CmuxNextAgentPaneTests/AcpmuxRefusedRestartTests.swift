import Darwin
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A daemon another binary runs on this app's acpmux socket (2026-10-22: a NIGHTLY's shared
/// `~/.acpmux` held by another install's acpmux) left the chat stuck: the error named no binary,
/// and Retry asked the same daemon again forever. The refusal names the binary and its signing
/// team, offers Restart acpmux, and that restart replaces the daemon with this app's own,
/// keeping its sessions.
@Suite(.serialized)
@MainActor
struct AcpmuxRefusedRestartTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// This test process's binary: the fake daemon's peer.
    private var ownPath: String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        _ = proc_pidpath(getpid(), &buffer, UInt32(buffer.count))
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
    }

    /// A refusal names the binary on the socket and says it has no team.
    @Test func aRefusalNamesTheBinaryOnTheSocket() throws {
        try withFakeDaemon { environment in
            let error = AcpmuxHost.refused(.olderDaemon, environment)
            let message = AgentPaneHostError.userMessage(for: error)
            #expect(message.contains(ownPath), "the refusal does not name the binary on the socket: \(message)")
        }
    }

    /// The page learns it may offer Restart acpmux, so it stops asking the same daemon again.
    @Test func aRefusedHandshakeOffersRestartAcpmux() async throws {
        try await withFakeDaemon { environment in
            let model = AgentPaneModel(host: AcpmuxHost(environment: environment))
            let reply = await model.respond(to: .reconnect)
            let error = try #require(reply["error"] as? [String: Any], "the daemon was accepted")
            let details = error["details"] as? [String: Any]
            #expect(details?["restartAcpmux"] as? Bool == true, "the refusal offers no restart: \(error)")
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
        try await withFakeDaemon(agentHosts: false) { environment in
            #expect(await AcpmuxSocketOwner.takeOver(environment: environment) == false)
        }
    }

    private func withFakeDaemon<T>(agentHosts: Bool = true, _ body: (AcpmuxEnvironment) async throws -> T) async throws -> T {
        let (root, environment, server) = try fakeDaemonEnvironment(agentHosts: agentHosts)
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: root)
        }
        return try await body(environment)
    }

    private func withFakeDaemon<T>(_ body: (AcpmuxEnvironment) throws -> T) throws -> T {
        let (root, environment, server) = try fakeDaemonEnvironment()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: root)
        }
        return try body(environment)
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
/// another app bundle, so the app never takes it over by itself) holds the home; the chat is
/// refused with the offer; Restart acpmux stops it; the next handshake runs this app's own.
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

    /// Another binary's daemon, the refusal, Restart acpmux, and the reconnect; the daemon that runs after.
    private func restart(otherBin: URL, bin: URL, socket: String,
                         environment: (URL) throws -> AcpmuxEnvironment) async throws -> Int32 {
        try await AcpmuxHost(environment: try environment(otherBin)).prewarm()
        let before = try #require(try await AcpmuxStatusClient.status(socketPath: socket, deadline: .seconds(15)).pid)

        let model = AgentPaneModel(host: AcpmuxHost(environment: try environment(bin)))
        let refused = await model.respond(to: .ready)
        let error = try #require(refused["error"] as? [String: Any], "another binary's daemon was accepted")
        #expect((error["details"] as? [String: Any])?["restartAcpmux"] as? Bool == true, "no restart offered: \(error)")

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
