import Foundation
import Testing
@testable import CmuxNextAgentPane

/// cx-6bgzj at the pane's reconnect boundary (``AcpmuxHost/reconnectHandshake(sessionId:)``):
/// acpmux killed with kill -9 leaves its `daemon.pid` naming a dead process, and an open chat's
/// reconnect starts a new daemon (which adopts the running agents). A daemon that was shut down
/// removed its pid file; then a reconnect still never starts one.
@Suite(.serialized)
struct AcpmuxCrashRestartTests {
    /// A short temp root (unix socket paths stay under the macOS limit) with a stand-in `acpmux`
    /// that records each launch and exits before it is ready.
    struct Fixture {
        let root: URL
        let environment: AcpmuxEnvironment
        var launched: Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent("launched").path) }

        init() throws {
            root = URL(fileURLWithPath: "/tmp/acr-\(UUID().uuidString.prefix(8))", isDirectory: true)
            let bin = root.appendingPathComponent("bin", isDirectory: true)
            let home = root.appendingPathComponent("home", isDirectory: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let acpmux = bin.appendingPathComponent("acpmux")
            try "#!/bin/sh\ntouch '\(root.path)/launched'\nexit 1\n".write(to: acpmux, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: acpmux.path)
            environment = try #require(AcpmuxEnvironment.resolve(
                build: nil, bundledBinDirectory: bin,
                environment: ["ACPMUX_HOME": home.path, "ACPMUX_SOCKET": home.appendingPathComponent("s.sock").path],
                executableOverride: nil
            ))
        }

        /// `daemon.pid` naming a process that has exited, as kill -9 leaves it.
        func leaveCrashedPidFile() throws {
            let gone = Process()
            gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            try gone.run()
            gone.waitUntilExit()
            try "\(gone.processIdentifier)".write(to: environment.home.appendingPathComponent("daemon.pid"),
                                                   atomically: true, encoding: .utf8)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func aReconnectAfterACrashStartsANewDaemon() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.leaveCrashedPidFile()
        let host = AcpmuxHost(daemons: AcpmuxLocalDaemons(), environment: fixture.environment)

        await #expect(throws: (any Error).self) { _ = try await host.reconnectHandshake(sessionId: "s") }
        #expect(fixture.launched, "a reconnect after kill -9 did not start acpmux; the chat stays on 'acpmux is not running'")
    }

    @Test func aReconnectAfterAShutdownStillStartsNothing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let host = AcpmuxHost(daemons: AcpmuxLocalDaemons(), environment: fixture.environment)

        await #expect(throws: AgentPaneHostError.daemonStopped) { _ = try await host.reconnectHandshake(sessionId: "s") }
        #expect(!fixture.launched, "a reconnect started a daemon that was shut down")
    }

    /// The card's explicit Retry is a fresh `ready` handshake, unlike the automatic reconnect
    /// loop above. A cleanly stopped app-owned daemon must therefore be started by that action.
    @Test func aManualRetryAfterAShutdownStartsTheBundledDaemon() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let host = AcpmuxHost(daemons: AcpmuxLocalDaemons(), environment: fixture.environment)

        await #expect(throws: (any Error).self) { _ = try await host.handshake(sessionId: "s") }
        #expect(fixture.launched, "manual Retry did not start the bundled acpmux after a clean stop")
    }

    @Test func theChiefsHostNeverStartsADaemonEvenAfterACrash() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.leaveCrashedPidFile()
        let host = AcpmuxHost(daemons: AcpmuxLocalDaemons(), environment: fixture.environment, startsDaemons: false)

        await #expect(throws: AgentPaneHostError.chiefStopped) { _ = try await host.reconnectHandshake(sessionId: "s") }
        #expect(!fixture.launched)
    }

    /// #25570: after a relaunch a restored Chief chat found nothing on the Chief home's socket and
    /// said "open Home to start it" until someone did. The tab asks the Chief host's owner to start
    /// instead, still never starting the daemon itself, and the page retries until it is up.
    @Test func aChiefTabWithNothingOnTheSocketAsksItsOwnerToStart() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let asks = Asks()
        let host = AcpmuxHost(daemons: AcpmuxLocalDaemons(), environment: fixture.environment, startsDaemons: false,
                              startOwner: { await asks.ask(answer: true) })

        await #expect(throws: AgentPaneHostError.chiefStarting) { _ = try await host.handshake(sessionId: "s") }
        await #expect(throws: AgentPaneHostError.chiefStarting) { _ = try await host.reconnectHandshake(sessionId: "s") }
        #expect(await asks.count == 2, "the Chief tab never asked the Chief host to start")
        #expect(!fixture.launched, "a Chief tab started the Chief home's daemon itself (cx-ebm.54)")
        #expect(!AgentPaneHostError.userMessage(for: AgentPaneHostError.chiefStarting).contains("open Home"))
    }

    /// An owner that will not start (after `cmux chief shutdown`) leaves the chat stopped.
    @Test func aChiefTabWhoseOwnerWillNotStartStaysStopped() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let asks = Asks()
        let host = AcpmuxHost(daemons: AcpmuxLocalDaemons(), environment: fixture.environment, startsDaemons: false,
                              startOwner: { await asks.ask(answer: false) })

        await #expect(throws: AgentPaneHostError.chiefStopped) { _ = try await host.reconnectHandshake(sessionId: "s") }
        #expect(await asks.count == 1)
        #expect(!fixture.launched)
    }

    /// An app-owned daemon never asks: it starts its own.
    @Test func anOwnedHostNeverAsksAnOwner() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let asks = Asks()
        let host = AcpmuxHost(daemons: AcpmuxLocalDaemons(), environment: fixture.environment, startOwner: { await asks.ask(answer: true) })

        await #expect(throws: AgentPaneHostError.daemonStopped) { _ = try await host.reconnectHandshake(sessionId: "s") }
        #expect(await asks.count == 0)
    }

    actor Asks {
        private(set) var count = 0
        func ask(answer: Bool) -> Bool {
            count += 1
            return answer
        }
    }
}
