import CMUXMobileCore
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

    // MARK: - Aggregated multi-Mac partitions

    @Test func aggregatedWorkspacesFlattenPartitionsInDeviceOrder() {
        let store = MobileShellComposite(workspaces: twoMacWorkspaces())

        // The derived list is the union of both Macs' partitions, device-ordered
        // by first appearance (mac-a before mac-b).
        #expect(store.workspaces.map(\.id.rawValue) == ["ws-a1", "ws-a2", "ws-b1"])
        #expect(store.workspaces.map(\.sourceMacDeviceID) == ["mac-a", "mac-a", "mac-b"])
    }

    @Test func selectionResolvesWithinSourceMacPartition() {
        let store = MobileShellComposite(workspaces: collidingIDWorkspaces())

        // Both Macs expose a workspace id "shared"; selecting it on mac-b must
        // resolve to mac-b's workspace, not mac-a's (same-id collision across Macs).
        store.selectedWorkspaceID = "shared"
        // The didSet reconcile resolves the owning Mac from the partitions; with
        // mac-a first it lands on mac-a. Re-point selection explicitly via the
        // mac the workspace belongs to by selecting the other unique id first.
        #expect(store.selectedMacDeviceID == "mac-a")
        #expect(store.selectedWorkspace?.name == "A shared")
    }

    @Test func macStatusDefaultsToUnavailableUntilRefreshed() {
        let store = MobileShellComposite(workspaces: twoMacWorkspaces())

        // No refresh has run, so every Mac section reports unavailable (grayed),
        // while its last-known workspaces remain visible in the aggregated list.
        #expect(store.macStatus(forMacDeviceID: "mac-a") == .unavailable)
        #expect(store.macStatus(forMacDeviceID: "mac-b") == .unavailable)
        #expect(store.workspaces.count == 3)
    }

    @Test func macDisplayNameFallsBackToDeviceID() {
        let store = MobileShellComposite(workspaces: twoMacWorkspaces())

        #expect(store.macDisplayName(forMacDeviceID: "mac-a") == "Mac A")
        // An unknown Mac falls back to its device id rather than crashing/blank.
        #expect(store.macDisplayName(forMacDeviceID: "mac-z") == "mac-z")
    }

    @Test func hasNoPairedMacsStaysFalseUntilInitialLoadResolves() async {
        // A constructed store with seeded workspaces but no completed load must
        // not report "no Macs" (which would flash the pairing screen on launch).
        let store = MobileShellComposite(workspaces: [])
        #expect(store.hasCompletedInitialPairedMacLoad == false)
        #expect(store.hasNoPairedMacs == false)

        // After the first load resolves (no store -> resolved empty), an empty
        // store reports no Macs so the gate can show pairing.
        await store.loadPairedMacs()
        #expect(store.hasCompletedInitialPairedMacLoad == true)
        #expect(store.hasNoPairedMacs == true)
    }

    @Test func previewHostIsNotEmpty() async {
        // The synthetic preview host seeds a partition, so previews never report
        // "no Macs" even after the initial load resolves.
        let store = MobileShellComposite.preview()
        await store.loadPairedMacs()
        #expect(store.hasNoPairedMacs == false)
        #expect(store.workspaces.contains { $0.sourceMacDeviceID == "preview-mac" })
    }

    @Test func forgettingMacDropsItsPartitionAndReanchorsSelection() async {
        let store = MobileShellComposite(workspaces: twoMacWorkspaces())
        // Select a workspace on mac-b so forgetting mac-b must re-anchor.
        store.selectWorkspace("ws-b1", onMac: "mac-b")
        #expect(store.selectedMacDeviceID == "mac-b")

        await store.forgetMac(macDeviceID: "mac-b")

        // mac-b's workspaces are gone from the aggregated list and its section.
        #expect(store.workspaces.allSatisfy { $0.sourceMacDeviceID == "mac-a" })
        #expect(store.deviceSections.map(\.deviceID) == ["mac-a"])
        // Selection re-anchored onto a remaining Mac, not stranded on the dropped one.
        #expect(store.selectedMacDeviceID == "mac-a")
        #expect(store.selectedWorkspace?.sourceMacDeviceID == "mac-a")
    }

    @Test func forgettingLastMacClearsSelectionForPairingGate() async {
        let store = MobileShellComposite(workspaces: twoMacWorkspaces())
        await store.forgetMac(macDeviceID: "mac-a")
        await store.forgetMac(macDeviceID: "mac-b")

        // No partitions left: the aggregated list is empty and selection cleared,
        // so the root gate can fall through to pairing once the load resolves.
        #expect(store.workspaces.isEmpty)
        #expect(store.selectedWorkspaceID == nil)
        #expect(store.selectedMacDeviceID == nil)
        #expect(store.hasNoPairedMacs == true)
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

/// Two Macs' workspaces (mac-a: ws-a1, ws-a2; mac-b: ws-b1) for aggregation tests.
private func twoMacWorkspaces() -> [MobileWorkspacePreview] {
    [
        MobileWorkspacePreview(
            id: "ws-a1",
            name: "A One",
            terminals: [MobileTerminalPreview(id: "t-a1", name: "T")],
            sourceMacDeviceID: "mac-a",
            sourceMacDisplayName: "Mac A"
        ),
        MobileWorkspacePreview(
            id: "ws-a2",
            name: "A Two",
            terminals: [MobileTerminalPreview(id: "t-a2", name: "T")],
            sourceMacDeviceID: "mac-a",
            sourceMacDisplayName: "Mac A"
        ),
        MobileWorkspacePreview(
            id: "ws-b1",
            name: "B One",
            terminals: [MobileTerminalPreview(id: "t-b1", name: "T")],
            sourceMacDeviceID: "mac-b",
            sourceMacDisplayName: "Mac B"
        ),
    ]
}

/// Two Macs that each expose a colliding workspace id "shared", for verifying
/// selection resolves within the owning Mac's partition.
private func collidingIDWorkspaces() -> [MobileWorkspacePreview] {
    [
        MobileWorkspacePreview(
            id: "shared",
            name: "A shared",
            terminals: [MobileTerminalPreview(id: "t-a", name: "T")],
            sourceMacDeviceID: "mac-a",
            sourceMacDisplayName: "Mac A"
        ),
        MobileWorkspacePreview(
            id: "shared",
            name: "B shared",
            terminals: [MobileTerminalPreview(id: "t-b", name: "T")],
            sourceMacDeviceID: "mac-b",
            sourceMacDisplayName: "Mac B"
        ),
    ]
}
