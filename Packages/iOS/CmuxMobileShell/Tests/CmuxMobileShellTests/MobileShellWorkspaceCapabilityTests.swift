import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileShellWorkspaceCapabilityTests {
    @Test func workspaceMutationCapabilitiesAreVersionAndTicketGated() async throws {
        let oldMac = try await connectedStore(capabilities: [
            "events.v1",
            "terminal.render_grid.v1",
            "terminal.replay.v1",
            "workspace.actions.v1",
        ])
        #expect(oldMac.store.supportsWorkspaceActions)
        #expect(!oldMac.store.supportsWorkspaceReadStateActions && !oldMac.store.supportsWorkspaceCloseActions)
        #expect(!oldMac.store.supportsWorkspaceMoveActions && !oldMac.store.supportsWorkspaceGroupActions)
        #expect(!oldMac.store.supportsWorkspaceCreateInGroup)

        let currentCapabilities = [
            "events.v1",
            "terminal.render_grid.v1",
            "terminal.replay.v1",
            "workspace.actions.v1",
            "workspace.read_state.v1",
            "workspace.close.v1",
            "workspace.move.v1",
            "workspace.group_actions.v1",
            "workspace.create_in_group.v1",
        ]
        let scoped = try await connectedStore(capabilities: currentCapabilities)
        #expect(scoped.store.supportsWorkspaceReadStateActions && scoped.store.supportsWorkspaceCloseActions)
        #expect(!scoped.store.supportsWorkspaceMoveActions && !scoped.store.supportsWorkspaceGroupActions)
        #expect(!scoped.store.supportsWorkspaceCreateInGroup)

        let macWide = try await connectedStore(
            capabilities: currentCapabilities,
            ticketWorkspaceID: "",
            ticketTerminalID: nil
        )
        #expect(macWide.store.supportsWorkspaceMoveActions && macWide.store.supportsWorkspaceGroupActions)
        #expect(macWide.store.supportsWorkspaceCreateInGroup)
    }

    private func connectedStore(
        capabilities: [String],
        ticketWorkspaceID: String = "live-workspace",
        ticketTerminalID: String? = "live-terminal"
    ) async throws -> (store: MobileShellComposite, router: LivenessHostRouter) {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        await router.setCapabilities(capabilities)
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(router: router, box: box),
            now: { clock.now }
        )
        let store = MobileShellComposite.preview(runtime: runtime)
        store.signIn()
        let connected = await store.connectPairingURL(try attachURL(for: try ticket(
            clock: clock,
            workspaceID: ticketWorkspaceID,
            terminalID: ticketTerminalID
        )))
        #expect(connected, "scripted connect must succeed")
        let resolved = try await pollUntil { await router.count(of: "mobile.host.status") >= 1 }
        #expect(resolved, "scripted connect must resolve host capabilities")
        return (store, router)
    }

    private func ticket(
        clock: TestClock,
        workspaceID: String,
        terminalID: String?
    ) throws -> CmxAttachTicket {
        let route = try CmxAttachRoute(
            id: "debug_loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56584)
        )
        return try CmxAttachTicket(
            workspaceID: workspaceID,
            terminalID: terminalID,
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
            routes: [route],
            expiresAt: clock.now.addingTimeInterval(3600),
            authToken: "ticket-secret"
        )
    }
}
