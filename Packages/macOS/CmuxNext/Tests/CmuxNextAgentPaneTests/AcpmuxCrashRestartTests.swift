import Foundation
import Testing
@testable import CmuxNextAgentPane

/// cx-6bgzj at the pane's reconnect boundary (``AcpmuxHost/reconnectHandshake(sessionId:)``):
/// acpmux killed with kill -9 leaves its `daemon.pid` naming a dead process, and an open chat's
/// reconnect starts a new daemon (which adopts the running agents). A daemon that was shut down
/// removed its pid file; a reconnect starts that one too (a relaunch after an update finds it so),
/// unless a restart this launch is carrying out is about to.
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

    /// After an update the relaunched app finds its daemon shut down cleanly (no pid file, so not a
    /// crash) and holds no mark of the stop: every restored chat's reconnect ended as "The agent
    /// service stopped." with a Retry. The reconnect starts the daemon itself, and never says so.
    @Test func aReconnectAfterAShutdownStartsTheBundledDaemon() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let host = AcpmuxHost(daemons: AcpmuxLocalDaemons(), environment: fixture.environment)

        let error = await #expect(throws: AgentPaneHostError.self) { _ = try await host.reconnectHandshake(sessionId: "s") }
        #expect(fixture.launched, "a reconnect left a cleanly stopped daemon down; the chat waits for a Retry")
        #expect(error != .daemonStopped)
        #expect(error?.isTransient == true, "the reconnect that starts the daemon showed a line: \(String(describing: error))")
    }

    /// No failure of the app's own stopped daemon asks the person to retry: the page's retries
    /// start it (above), so the handshake's failure is a reconnecting one.
    @Test func aStoppedDaemonIsNeverSaidAtOnce() {
        #expect(AgentPaneHostError.daemonStopped.isTransient)
    }

    /// A person's restart from another pane stops the daemon, and the reconnects of the other
    /// chats start nothing while that restart's own start runs; one that never came is started by
    /// the next reconnect after its window.
    @Test func aReconnectAfterAPersonsRestartStaysQuietOnlyForItsWindow() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let daemons = AcpmuxLocalDaemons()
        let stopped = ContinuousClock.now
        daemons.noteStoppedByPerson(home: fixture.environment.home, at: stopped)
        let host = AcpmuxHost(daemons: daemons, environment: fixture.environment)

        await #expect(throws: AgentPaneHostError.daemonRestarting) { _ = try await host.reconnectHandshake(sessionId: "s") }
        #expect(!fixture.launched, "a reconnect during a person's restart started a daemon of its own")
        #expect(daemons.stoppedByPerson(home: fixture.environment.home, at: stopped + .seconds(19)))
        #expect(!daemons.stoppedByPerson(home: fixture.environment.home, at: stopped + AcpmuxLocalDaemons.personRestartWindow),
                "a restart that never started the daemon kept the pane quiet past its window")
    }

    /// An attached daemon (`CMUX_NEXT_ACPMUX_ATTACH`) is another app's to start: its stop stays quiet
    /// (no Retry this app could not honor), and the pane finds it when its owner starts it again.
    @Test func anAttachedDaemonsStopStaysQuiet() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var attached = fixture.environment
        attached.isAttached = true
        let host = AcpmuxHost(daemons: AcpmuxLocalDaemons(), environment: attached)

        await #expect(throws: AgentPaneHostError.daemonRestarting) { _ = try await host.reconnectHandshake(sessionId: "s") }
        await #expect(throws: AgentPaneHostError.daemonRestarting) { _ = try await host.handshake(sessionId: "s") }
        #expect(!fixture.launched, "this app started an attached daemon")
    }

    /// A handoff or Restart agent service stopping the daemon ends without the person: its reconnect
    /// stays quiet (transient) while the start that follows runs, and starts nothing itself.
    @Test func aReconnectWhileAHandoffStopsTheDaemonStaysQuiet() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let daemons = AcpmuxLocalDaemons()
        daemons.mark(home: fixture.environment.home, restarting: true)
        let host = AcpmuxHost(daemons: daemons, environment: fixture.environment)

        await #expect(throws: AgentPaneHostError.daemonRestarting) { _ = try await host.reconnectHandshake(sessionId: "s") }
        #expect(AgentPaneHostError.daemonRestarting.isTransient)
        #expect(!fixture.launched, "a reconnect during a handoff started a daemon of its own")
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

        await #expect(throws: (any Error).self) { _ = try await host.reconnectHandshake(sessionId: "s") }
        #expect(await asks.count == 0)
        #expect(fixture.launched)
    }

    actor Asks {
        private(set) var count = 0
        func ask(answer: Bool) -> Bool {
            count += 1
            return answer
        }
    }
}
