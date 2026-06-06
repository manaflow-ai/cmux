import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// Behavior tests for ``MobileShellComposite`` in preview mode (no injected
/// ``MobileSyncRuntime``), where connection, workspace, and selection logic run
/// entirely against the in-memory preview host without any transport. The
/// scripted-transport / remote-RPC behaviors stay in the iOS feature test target
/// because they construct the feature-level `CMUXMobileRuntime` and its test
/// doubles.
@MainActor
@Suite struct MobileShellCompositePreviewTests {
    @Test func startsAtSignInWithoutConnection() {
        let store = MobileShellComposite.preview()

        #expect(store.phase == .signIn)
        #expect(store.isSignedIn == false)
        #expect(store.connectionState == .disconnected)
        #expect(store.selectedWorkspace?.name == "cmux")
        #expect(store.selectedTerminalID?.rawValue == "terminal-build")
    }

    @Test func signInMovesToPairingUntilPreviewCodeConnects() {
        let store = MobileShellComposite.preview()

        store.signIn()
        #expect(store.phase == .pairing)

        store.connectPreviewHost()
        #expect(store.phase == .pairing)

        store.pairingCode = "debug"
        store.connectPreviewHost()
        #expect(store.phase == .workspaces)
        #expect(store.connectedHostName == "cmux-macbook")
    }

    @Test func signOutReturnsToPreviewHostState() {
        let store = MobileShellComposite.preview()
        store.signIn()
        store.pairingCode = "debug"
        store.connectPreviewHost()

        store.signOut()

        #expect(store.phase == .signIn)
        #expect(store.connectionState == .disconnected)
        #expect(store.connectedHostName.isEmpty)
        #expect(store.selectedWorkspace?.name == "cmux")
    }

    @Test func createWorkspaceSelectsNewWorkspaceAndTerminal() {
        let store = MobileShellComposite.preview()
        store.signIn()
        store.pairingCode = "debug"
        store.connectPreviewHost()

        store.createWorkspace()

        #expect(store.workspaces.count == 3)
        #expect(store.selectedWorkspace?.id.rawValue == "workspace-3")
        #expect(store.selectedTerminalID?.rawValue == "workspace-3-terminal-1")
    }

    @Test func createTerminalAddsTerminalToSelectedWorkspace() {
        let store = MobileShellComposite.preview()
        store.signIn()
        store.pairingCode = "debug"
        store.connectPreviewHost()

        store.createTerminal()

        #expect(store.selectedWorkspace?.id.rawValue == "workspace-main")
        #expect(store.selectedWorkspace?.terminals.count == 4)
        #expect(store.selectedTerminalID?.rawValue == "workspace-main-terminal-4")
    }

    @Test func selectingWorkspaceReconcilesTerminalSelection() {
        let store = MobileShellComposite.preview()
        store.signIn()
        store.pairingCode = "debug"
        store.connectPreviewHost()
        store.selectTerminal("terminal-agent")

        store.selectedWorkspaceID = "workspace-docs"

        #expect(store.selectedWorkspace?.id.rawValue == "workspace-docs")
        #expect(store.selectedTerminalID?.rawValue == "terminal-notes")
    }

    @Test func activeMacReconnectRouteSkipsUnsupportedLoopbackRoute() throws {
        let loopback = try hostPortRoute(
            kind: .debugLoopback,
            host: "127.0.0.1",
            port: CmxMobileDefaults.defaultHostPort
        )
        let tailscale = try hostPortRoute(
            kind: .tailscale,
            host: "100.71.210.41",
            port: CmxMobileDefaults.defaultHostPort
        )

        let route = MobileShellComposite.firstReconnectHostPortRoute(
            [loopback, tailscale],
            supportedKinds: [.tailscale]
        )

        #expect(route?.0 == "100.71.210.41")
        #expect(route?.1 == CmxMobileDefaults.defaultHostPort)
    }

    @Test func reconnectPublishesActivePairedMacBeforeRouteSelection() async throws {
        let route = try hostPortRoute(
            kind: .debugLoopback,
            host: "127.0.0.1",
            port: CmxMobileDefaults.defaultHostPort
        )
        let pairedMac = MobilePairedMac(
            macDeviceID: "mac-offline",
            displayName: "Studio Offline",
            routes: [route],
            createdAt: Date(timeIntervalSince1970: 1),
            lastSeenAt: Date(timeIntervalSince1970: 2),
            isActive: true,
            stackUserID: nil
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: PreviewPairedMacStore(activeMac: pairedMac)
        )

        let didConnect = await store.reconnectActiveMacIfAvailable(stackUserID: nil)

        #expect(didConnect == false)
        #expect(store.activePairedMac?.macDeviceID == "mac-offline")
        #expect(store.activePairedMac?.displayName == "Studio Offline")
        #expect(store.activeTicket == nil)
        #expect(store.connectedHostName.isEmpty)
    }
}

private func hostPortRoute(
    kind: CmxAttachTransportKind,
    host: String,
    port: Int,
    priority: Int = 0
) throws -> CmxAttachRoute {
    try CmxAttachRoute(
        id: kind.rawValue,
        kind: kind,
        endpoint: .hostPort(host: host, port: port),
        priority: priority
    )
}

private actor PreviewPairedMacStore: MobilePairedMacStoring {
    private var mac: MobilePairedMac?

    init(activeMac: MobilePairedMac?) {
        self.mac = activeMac
    }

    func upsert(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        markActive: Bool,
        stackUserID: String?,
        now: Date
    ) async throws {
        mac = MobilePairedMac(
            macDeviceID: macDeviceID,
            displayName: displayName,
            routes: routes,
            createdAt: now,
            lastSeenAt: now,
            isActive: markActive,
            stackUserID: stackUserID
        )
    }

    func loadAll(stackUserID: String?) async throws -> [MobilePairedMac] {
        mac.map { [$0] } ?? []
    }

    func activeMac(stackUserID: String?) async throws -> MobilePairedMac? {
        mac
    }

    func setActive(macDeviceID: String) async throws {}

    func remove(macDeviceID: String) async throws {
        if mac?.macDeviceID == macDeviceID {
            mac = nil
        }
    }

    func removeAll() async throws {
        mac = nil
    }
}
