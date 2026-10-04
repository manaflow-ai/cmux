import CmuxNextDesign
import CmuxNextServer
import CmuxNextServerHelper
import Foundation
import ServiceManagement
import Testing
@testable import CmuxNextApp

/// Make This Mac a Server registers the server LaunchAgent only behind the
/// `server.agent.allowRegister` switch (off by default) until the bundled CLI
/// ships `cmux host run`: a registered agent would exit and restart forever.
@MainActor
@Suite struct ServerLaunchAgentTests {
    final class Fake {
        var calls: [String] = []
        var status: SMAppService.Status = .notRegistered
        var statusAfterRegister: SMAppService.Status = .enabled
    }

    private func agent(_ fake: Fake, bundled: Bool = true, allow: Bool, hostRun: Bool = true) -> ServerLaunchAgent {
        ServerLaunchAgent(
            isBundled: { bundled },
            allowRegister: { allow },
            hostRunSupported: { fake.calls.append("hostRunSupported"); return hostRun },
            service: .init(status: { fake.calls.append("status"); return fake.status },
                           register: { fake.calls.append("register"); fake.status = fake.statusAfterRegister },
                           openLoginItems: { fake.calls.append("openLoginItems") }))
    }

    @Test func switchIsOffByDefaultAndListedInDebugSettings() {
        #expect(ServerTunables.agentAllowRegister.key == "server.agent.allowRegister")
        #expect(ServerTunables.agentAllowRegister.value(in: TunableStore()) == false)
        #expect(ServerTunables.all.contains { $0.key == "server.agent.allowRegister" })
    }

    @Test func switchOffRefusesWithoutTouchingServiceManagement() {
        let fake = Fake()
        #expect(throws: ServerLaunchAgent.Failure.notReady) { try agent(fake, allow: false).register() }
        #expect(fake.calls.isEmpty)
    }

    @Test func switchOnRegisters() throws {
        let fake = Fake()
        try agent(fake, allow: true).register()
        #expect(fake.calls == ["hostRunSupported", "status", "register", "status"])
    }

    @Test func switchOnKeepsAnEnabledAgent() throws {
        let fake = Fake()
        fake.status = .enabled
        try agent(fake, allow: true).register()
        #expect(fake.calls == ["hostRunSupported", "status"])
    }

    @Test func switchOnAsksForApproval() {
        let fake = Fake()
        fake.statusAfterRegister = .requiresApproval
        #expect(throws: ServerLaunchAgent.Failure.requiresApproval) { try agent(fake, allow: true).register() }
        #expect(fake.calls == ["hostRunSupported", "status", "register", "status", "openLoginItems"])
    }

    /// The switch on, but the bundled CLI has no `host` verb: the agent is
    /// not registered, so launchd never starts a crash loop.
    @Test func switchOnWithoutHostRunDoesNotRegister() {
        let fake = Fake()
        #expect(throws: ServerLaunchAgent.Failure.hostRunUnsupported) {
            try agent(fake, allow: true, hostRun: false).register()
        }
        #expect(fake.calls == ["hostRunSupported"])
    }

    /// The support check runs only after the switch: with the switch off,
    /// nothing is probed.
    @Test func switchOffDoesNotProbeHostRun() {
        let fake = Fake()
        #expect(throws: ServerLaunchAgent.Failure.notReady) { try agent(fake, allow: false, hostRun: false).register() }
        #expect(fake.calls.isEmpty)
    }

    @Test func noPlistMeansNotInBuild() {
        let fake = Fake()
        #expect(throws: ServerLaunchAgent.Failure.notInBuild) { try agent(fake, bundled: false, allow: true).register() }
        #expect(fake.calls.isEmpty)
    }

    /// Stop Serving does not read the switch: with it off (the default), an
    /// agent registered earlier is still removed.
    @Test func stopServingUnregistersWithTheSwitchOff() async throws {
        #expect(ServerTunables.agentAllowRegister.value(in: TunableStore()) == false)
        let fake = Fake()
        fake.status = .enabled
        let ledger = ServerFixLedger(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-ledger-\(UUID().uuidString)/ledger.json"))
        let stop = ServerStopServing(
            agent: ServerServiceRegistration(status: { fake.status }, unregister: {
                fake.calls.append("unregister")
                fake.status = .notRegistered
            }),
            helper: nil,
            revert: { (_: ServerFix) async throws(ServerHelperClient.Failure) in },
            gate: ServerFixGate(), ledger: ledger)
        try await stop.run()
        #expect(fake.calls == ["unregister"])
    }
}
