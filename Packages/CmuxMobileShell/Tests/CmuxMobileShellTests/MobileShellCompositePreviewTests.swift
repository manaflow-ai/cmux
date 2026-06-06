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

    @Test func signOutClearsDiagnosticsEventsFromPreviousSession() async {
        let store = MobileShellComposite.preview()
        store.signIn()
        store.pairingCode = "debug"
        store.connectPreviewHost()
        #expect(store.diagnosticsImmediateEventLines.contains { $0.contains("cmux-macbook") })

        store.signOut()
        let immediateLines = await store.diagnosticsImmediateEventLinesForReport()

        #expect(!immediateLines.contains { $0.contains("cmux-macbook") })
        #expect(immediateLines.contains("auth.signedIn=false"))
        #expect(immediateLines.contains("conn.state=disconnected host=-"))
    }

    @Test func repeatedSignOutDoesNotClearSignOutDiagnosticsEvents() async {
        let store = MobileShellComposite.preview()
        store.signIn()
        store.pairingCode = "debug"
        store.connectPreviewHost()

        store.signOut()
        store.signOut()
        let immediateLines = await store.diagnosticsImmediateEventLinesForReport()

        #expect(!immediateLines.contains { $0.contains("cmux-macbook") })
        #expect(immediateLines.contains("auth.signedIn=false"))
        #expect(immediateLines.contains("conn.state=disconnected host=-"))
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

    @Test func rescanQRForgetsActivePairedMacWithoutActiveTicket() async throws {
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
        let pairedMacStore = PreviewPairedMacStore(activeMac: pairedMac)
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedMacStore
        )
        let didConnect = await store.reconnectActiveMacIfAvailable(stackUserID: nil)
        #expect(didConnect == false)
        #expect(store.activeTicket == nil)
        #expect(store.activePairedMac?.macDeviceID == "mac-offline")

        let forgetTask = store.disconnectAndForgetActiveMac()
        await forgetTask?.value

        #expect(store.activePairedMac == nil)
        let remaining = try await pairedMacStore.loadAll(stackUserID: nil)
        #expect(remaining.isEmpty)
    }

    @Test func pairingURLPublishesActivePairedMacForDiagnostics() async throws {
        let route = try hostPortRoute(
            kind: .debugLoopback,
            host: "127.0.0.1",
            port: CmxMobileDefaults.defaultHostPort
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace-main",
            terminalID: "terminal-main",
            macDeviceID: "mac-ticket",
            macDisplayName: "Ticket Mac",
            routes: [route],
            expiresAt: Date(timeIntervalSinceNow: 300)
        )
        let store = MobileShellComposite(isSignedIn: true, pairedMacStore: PreviewPairedMacStore(activeMac: nil))
        store.pairingCode = try attachURL(for: ticket)

        await store.connectPairingInput()

        #expect(store.connectionState == .connected)
        #expect(store.activePairedMac?.macDeviceID == "mac-ticket")
        #expect(store.activePairedMac?.displayName == "Ticket Mac")
    }

    @Test func loadAndForgetReconcilesActivePairedMac() async throws {
        let route = try hostPortRoute(
            kind: .debugLoopback,
            host: "127.0.0.1",
            port: CmxMobileDefaults.defaultHostPort
        )
        let pairedMac = MobilePairedMac(
            macDeviceID: "mac-forget",
            displayName: "Forget Me",
            routes: [route],
            createdAt: Date(timeIntervalSince1970: 1),
            lastSeenAt: Date(timeIntervalSince1970: 2),
            isActive: true,
            stackUserID: "user-1"
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: PreviewPairedMacStore(activeMac: pairedMac),
            identityProvider: PreviewIdentityProvider(userID: "user-1")
        )

        await store.loadPairedMacs()
        #expect(store.activePairedMac?.macDeviceID == "mac-forget")

        await store.forgetMac(macDeviceID: "mac-forget")

        #expect(store.pairedMacs.isEmpty)
        #expect(store.activePairedMac == nil)
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

private func attachURL(for ticket: CmxAttachTicket) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let payload = try base64URLEncode(encoder.encode(ticket))
    return "cmux-ios://attach?v=\(ticket.version)&payload=\(payload)"
}

private func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
