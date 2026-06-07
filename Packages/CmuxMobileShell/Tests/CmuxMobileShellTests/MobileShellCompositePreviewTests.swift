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

    @Test func createTerminalUsesExplicitWorkspaceContextOverStaleSelection() {
        let store = MobileShellComposite.preview()
        store.signIn()
        store.pairingCode = "debug"
        store.connectPreviewHost()
        // Selection drifts to a different workspace than the one the "+" was tapped on.
        store.selectedWorkspaceID = "workspace-docs"

        store.createTerminal(in: "workspace-main")

        // The new terminal lands in the explicitly-targeted workspace, not the selected one.
        #expect(store.selectedWorkspace?.id.rawValue == "workspace-main")
        #expect(store.selectedWorkspace?.terminals.count == 4)
        #expect(store.selectedTerminalID?.rawValue == "workspace-main-terminal-4")
    }

    @Test func createdTerminalIsAutoFocusSuppressedUntilConsumed() throws {
        let store = MobileShellComposite.preview()
        store.signIn()
        store.pairingCode = "debug"
        store.connectPreviewHost()

        store.createTerminal()

        // A freshly created terminal must not grab the keyboard on mount.
        let created = try #require(store.selectedTerminalID).rawValue
        #expect(store.shouldAutoFocusTerminalSurface(created) == false)
        // Its surface appearing consumes the one-shot suppression.
        store.consumeTerminalAutoFocusSuppression(for: created)
        #expect(store.shouldAutoFocusTerminalSurface(created) == true)
    }

    @Test func createdWorkspaceTerminalIsAutoFocusSuppressed() {
        let store = MobileShellComposite.preview()
        store.signIn()
        store.pairingCode = "debug"
        store.connectPreviewHost()

        store.createWorkspace()

        #expect(store.selectedTerminalID?.rawValue == "workspace-3-terminal-1")
        #expect(store.shouldAutoFocusTerminalSurface("workspace-3-terminal-1") == false)
    }

    @Test func pushNavigationSelectionStaysAutoFocusable() throws {
        let store = MobileShellComposite.preview()
        store.signIn()
        store.pairingCode = "debug"
        store.connectPreviewHost()

        // A chrome create suppresses the new terminal...
        store.createTerminal()
        let created = try #require(store.selectedTerminalID).rawValue
        #expect(store.shouldAutoFocusTerminalSurface(created) == false)

        // ...but a push-notification deep link to an existing terminal is a
        // focus intent and must still autofocus: suppression attaches to the
        // created id, not to "whatever selection comes next".
        store.selectTerminal("terminal-agent")
        #expect(store.shouldAutoFocusTerminalSurface("terminal-agent") == true)
    }

    @Test func chromeTerminalSwitchSuppressesTargetButNotReconfirm() throws {
        let store = MobileShellComposite.preview()
        store.signIn()
        store.pairingCode = "debug"
        store.connectPreviewHost()

        // Re-confirming the already-selected terminal from the picker re-attaches
        // nothing, so it must not leave a dangling suppression.
        let current = try #require(store.selectedTerminalID)
        store.selectTerminalFromChrome(current)
        #expect(store.shouldAutoFocusTerminalSurface(current.rawValue) == true)

        // Switching to a different terminal IS chrome: suppress its autofocus.
        store.selectTerminalFromChrome("terminal-agent")
        #expect(store.selectedTerminalID?.rawValue == "terminal-agent")
        #expect(store.shouldAutoFocusTerminalSurface("terminal-agent") == false)
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

    @Test func rescanQRForgetsPersistedPairedMacWhenManualTicketIsActive() async throws {
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
            stackUserID: "user-1"
        )
        let pairedMacStore = PreviewPairedMacStore(activeMac: pairedMac)
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedMacStore,
            identityProvider: PreviewIdentityProvider(userID: "user-1")
        )
        await store.loadPairedMacs()
        #expect(store.pairedMacs.first?.macDeviceID == "mac-offline")

        let manualTicket = try CmxAttachTicket(
            workspaceID: "manual-workspace",
            terminalID: nil,
            macDeviceID: "manual-127.0.0.1:\(CmxMobileDefaults.defaultHostPort)",
            macDisplayName: "Manual Host",
            routes: [route],
            expiresAt: Date(timeIntervalSinceNow: 300)
        )
        store.pairingCode = try attachURL(for: manualTicket)
        await store.connectPairingInput()
        #expect(store.activeTicket?.macDeviceID.hasPrefix("manual-") == true)

        let forgetTask = store.disconnectAndForgetActiveMac()
        await forgetTask?.value

        #expect(store.pairedMacs.isEmpty)
        let remaining = try await pairedMacStore.loadAll(stackUserID: "user-1")
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

    @Test func reconnectDoesNotPublishPairedMacAfterSignOutDuringStoreRead() async throws {
        let route = try hostPortRoute(
            kind: .debugLoopback,
            host: "127.0.0.1",
            port: CmxMobileDefaults.defaultHostPort
        )
        let pairedMac = MobilePairedMac(
            macDeviceID: "mac-stale",
            displayName: "Stale Mac",
            routes: [route],
            createdAt: Date(timeIntervalSince1970: 1),
            lastSeenAt: Date(timeIntervalSince1970: 2),
            isActive: true,
            stackUserID: "user-1"
        )
        let pairedMacStore = SuspendedActiveMacStore(activeMac: pairedMac)
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedMacStore,
            identityProvider: PreviewIdentityProvider(userID: "user-1")
        )

        let reconnect = Task { @MainActor in
            await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")
        }
        await pairedMacStore.waitForActiveMacRequest()

        store.signOut()
        await pairedMacStore.releaseActiveMac()
        let didReconnect = await reconnect.value

        #expect(didReconnect == false)
        #expect(store.activePairedMac == nil)
        #expect(store.connectionState == .disconnected)
    }

    @Test func reconnectDoesNotPublishPairedMacAfterForgetDuringStoreRead() async throws {
        let route = try hostPortRoute(
            kind: .debugLoopback,
            host: "127.0.0.1",
            port: CmxMobileDefaults.defaultHostPort
        )
        let pairedMac = MobilePairedMac(
            macDeviceID: "mac-stale",
            displayName: "Stale Mac",
            routes: [route],
            createdAt: Date(timeIntervalSince1970: 1),
            lastSeenAt: Date(timeIntervalSince1970: 2),
            isActive: true,
            stackUserID: "user-1"
        )
        let pairedMacStore = SuspendedActiveMacStore(activeMac: pairedMac)
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedMacStore,
            identityProvider: PreviewIdentityProvider(userID: "user-1")
        )

        let reconnect = Task { @MainActor in
            await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")
        }
        await pairedMacStore.waitForActiveMacRequest()

        _ = store.disconnectAndForgetActiveMac()
        await pairedMacStore.releaseActiveMac()
        let didReconnect = await reconnect.value

        #expect(didReconnect == false)
        let removedIDs = await pairedMacStore.removedMacDeviceIDs()
        #expect(removedIDs == ["mac-stale"])
        let remaining = try await pairedMacStore.loadAll(stackUserID: "user-1")
        #expect(remaining.isEmpty)
        #expect(store.activePairedMac == nil)
        #expect(store.connectionState == .disconnected)
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
