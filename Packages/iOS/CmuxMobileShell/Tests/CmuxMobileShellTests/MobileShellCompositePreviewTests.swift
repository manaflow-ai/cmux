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
        // Group sections are account-scoped: the previous account's group
        // names must not survive sign-out into the next session.
        store.replaceForegroundWorkspaceState(store.workspaces, groups: [
            MobileWorkspaceGroupPreview(
                id: "group-1",
                name: "previous account group",
                isCollapsed: false,
                isPinned: false,
                anchorWorkspaceID: "workspace-main"
            )
        ])

        store.signOut()

        #expect(store.phase == .signIn)
        #expect(store.connectionState == .disconnected)
        #expect(store.connectedHostName.isEmpty)
        #expect(store.selectedWorkspace?.name == "cmux")
        #expect(store.workspaceGroups.isEmpty)
    }

    @Test func currentTeamDidChangeKeepsForegroundWorkspacesLive() {
        let store = MobileShellComposite.preview()
        store.signIn()
        store.pairingCode = "debug"
        store.connectPreviewHost()
        store.replaceForegroundWorkspaceState([
            MobileWorkspacePreview(id: "ws-foreground", name: "Live", terminals: []),
        ])
        #expect(store.workspaces.map(\.id.rawValue) == ["ws-foreground"])
        let connectionBefore = store.connectionState

        // A team switch must re-scope lists lazily but NEVER drop the live
        // foreground terminal session.
        store.currentTeamDidChange()

        #expect(store.workspaces.map(\.id.rawValue) == ["ws-foreground"])
        #expect(store.connectionState == connectionBefore)
        // Team-scoped caches are cleared so they lazily repopulate for the new team.
        #expect(store.pairedMacs.isEmpty)
        #expect(store.registryDevices.isEmpty)
    }

    @Test func staleTeamLoadsDoNotClearCurrentTeamLists() async throws {
        let team = MutableTeamID("team-a")
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "team-a": [try Self.pairedMac(id: "mac-a", teamID: "team-a")],
                "team-b": [try Self.pairedMac(id: "mac-b", teamID: "team-b")],
            ],
            blockedTeams: ["team-a"]
        )
        let registry = DelayedTeamDeviceRegistry(
            teamIDProvider: { await team.value },
            devicesByTeam: [
                "team-a": [Self.registryDevice(id: "device-a")],
                "team-b": [Self.registryDevice(id: "device-b")],
            ],
            blockedTeams: ["team-a"]
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedStore,
            deviceRegistry: registry,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { await team.value }
        )

        let oldPairedLoad = Task { await store.loadPairedMacs() }
        let oldRegistryLoad = Task { await store.loadRegistryDevices() }
        await pairedStore.waitUntilLoadStarted(teamID: "team-a")
        await registry.waitUntilLoadStarted(teamID: "team-a")

        await team.set("team-b")
        store.currentTeamDidChange()
        await store.loadPairedMacs()
        await store.loadRegistryDevices()
        #expect(store.pairedMacs.map(\.macDeviceID) == ["mac-b"])
        #expect(store.registryDevices.map(\.deviceId) == ["device-b"])

        await pairedStore.release(teamID: "team-a")
        await registry.release(teamID: "team-a")
        _ = await oldPairedLoad.value
        _ = await oldRegistryLoad.value

        #expect(store.pairedMacs.map(\.macDeviceID) == ["mac-b"])
        #expect(store.registryDevices.map(\.deviceId) == ["device-b"])
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

    @Test func createWorkspaceInGroupWithoutConnectionReturnsNotConnected() {
        let store = MobileShellComposite.preview()
        let initialWorkspaceIDs = store.workspaces.map(\.id)

        let result = store.createWorkspace(inGroup: "group-offline")

        guard case .failure(.notConnected) = result else {
            return #expect(Bool(false), "offline group create should return a notConnected failure")
        }
        #expect(store.workspaces.map(\.id) == initialWorkspaceIDs)
    }

    @Test func duplicateCreateWorkspaceRequestAwaitsInFlightResult() async throws {
        let router = RoutingHostRouter()
        await router.setHoldFirstWorkspaceCreate(true)
        await router.setRejectWorkspaceCreate(true)
        let store = try await makeRoutingConnectedStore(router: router)

        let firstCreate = Task { @MainActor in
            await store.createWorkspaceRequest()
        }
        await router.awaitFirstWorkspaceCreateReached()
        let secondCreate = Task { @MainActor in
            await store.createWorkspaceRequest()
        }

        await router.releaseFirstWorkspaceCreate()
        let firstResult = await firstCreate.value
        let secondResult = await secondCreate.value

        guard case .failure(.rejected) = firstResult else {
            return #expect(Bool(false), "first create should report the host rejection")
        }
        guard case .failure(.rejected) = secondResult else {
            return #expect(Bool(false), "duplicate create should reuse the in-flight rejection")
        }
        #expect(await router.recordedWorkspaceCreateCount() == 1)
    }

    private static func pairedMac(id: String, teamID: String) throws -> MobilePairedMac {
        MobilePairedMac(
            macDeviceID: id,
            displayName: id,
            routes: [try CmxAttachRoute(id: "manual", kind: .tailscale, endpoint: .hostPort(host: "10.0.0.1", port: 22))],
            createdAt: Date(timeIntervalSince1970: 1),
            lastSeenAt: Date(timeIntervalSince1970: 2),
            isActive: false,
            stackUserID: "user-1",
            teamID: teamID
        )
    }

    private static func registryDevice(id: String) -> RegistryDevice {
        RegistryDevice(
            deviceId: id,
            platform: "mac",
            displayName: id,
            lastSeenAt: Date(timeIntervalSince1970: 2),
            instances: []
        )
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

    @Test func aggregationRowIDScopingPreservesCurrentSelection() {
        let store = MobileShellComposite.preview()
        store.signIn()
        let foregroundWorkspace = MobileWorkspacePreview(
            id: "w-foreground",
            macDeviceID: "mac-a",
            name: "Foreground",
            terminals: [MobileTerminalPreview(id: "terminal-foreground", name: "fg")]
        )
        let selectedWorkspace = MobileWorkspacePreview(
            id: "w-selected",
            macDeviceID: "mac-a",
            name: "Selected",
            terminals: [MobileTerminalPreview(id: "terminal-selected", name: "selected")]
        )
        let secondaryWorkspace = MobileWorkspacePreview(
            id: "w-secondary",
            macDeviceID: "mac-b",
            name: "Secondary",
            terminals: [MobileTerminalPreview(id: "terminal-secondary", name: "secondary")]
        )
        store.setWorkspaceStatesForTesting([
            "mac-a": MacWorkspaceState(
                macDeviceID: "mac-a",
                workspaces: [foregroundWorkspace, selectedWorkspace],
                status: .connected
            ),
        ], foregroundMacDeviceID: "mac-a")
        store.selectedWorkspaceID = "w-selected"
        store.selectedTerminalID = "terminal-selected"

        store.setWorkspaceStatesForTesting([
            "mac-a": MacWorkspaceState(
                macDeviceID: "mac-a",
                workspaces: [foregroundWorkspace, selectedWorkspace],
                status: .connected
            ),
            "mac-b": MacWorkspaceState(
                macDeviceID: "mac-b",
                workspaces: [secondaryWorkspace],
                status: .connected
            ),
        ], foregroundMacDeviceID: "mac-a")

        #expect(store.selectedWorkspace?.name == "Selected")
        #expect(store.selectedWorkspace?.rpcWorkspaceID.rawValue == "w-selected")
        #expect(store.selectedWorkspace?.macDeviceID == "mac-a")
        #expect(store.selectedTerminalID?.rawValue == "terminal-selected")
    }

    @Test func anonymousForegroundRowsDoNotExposeAggregateSentinel() {
        let store = MobileShellComposite.preview()
        store.signIn()
        let anonymousWorkspace = MobileWorkspacePreview(
            id: "w-anonymous",
            name: "Manual",
            terminals: [MobileTerminalPreview(id: "terminal-anonymous", name: "manual")]
        )
        let secondaryWorkspace = MobileWorkspacePreview(
            id: "w-secondary",
            macDeviceID: "mac-b",
            name: "Secondary",
            terminals: [MobileTerminalPreview(id: "terminal-secondary", name: "secondary")]
        )

        store.setWorkspaceStatesForTesting([
            MobileShellComposite.foregroundAnonymousKey: MacWorkspaceState(
                macDeviceID: MobileShellComposite.foregroundAnonymousKey,
                workspaces: [anonymousWorkspace],
                status: .connected
            ),
            "mac-b": MacWorkspaceState(
                macDeviceID: "mac-b",
                workspaces: [secondaryWorkspace],
                status: .connected
            ),
        ], foregroundMacDeviceID: nil)

        let foreground = store.workspaces.first { $0.rpcWorkspaceID.rawValue == "w-anonymous" }
        #expect(foreground?.macDeviceID == nil)
        #expect(foreground?.remoteWorkspaceID?.rawValue == "w-anonymous")
    }

    @Test func deeplinkWorkspaceResolutionUsesMacOwnerWhenWorkspaceIDsCollide() throws {
        let store = MobileShellComposite.preview()
        store.signIn()
        let workspaceA = MobileWorkspacePreview(
            id: "shared",
            macDeviceID: "mac-a",
            name: "Mac A",
            terminals: [MobileTerminalPreview(id: "terminal-shared", name: "a")]
        )
        let workspaceB = MobileWorkspacePreview(
            id: "shared",
            macDeviceID: "mac-b",
            name: "Mac B",
            terminals: [MobileTerminalPreview(id: "terminal-shared", name: "b")]
        )
        store.setWorkspaceStatesForTesting([
            "mac-a": MacWorkspaceState(
                macDeviceID: "mac-a",
                workspaces: [workspaceA],
                status: .connected
            ),
            "mac-b": MacWorkspaceState(
                macDeviceID: "mac-b",
                workspaces: [workspaceB],
                status: .connected
            ),
        ], foregroundMacDeviceID: "mac-a")

        let resolvedWorkspaceID = try #require(store.workspaceID(
            matchingRemoteWorkspaceID: "shared",
            macDeviceID: "mac-b"
        ))
        let resolvedSurfaceOwnerID = try #require(store.workspaceID(
            containingSurfaceID: "terminal-shared",
            macDeviceID: "mac-b"
        ))

        let workspace = try #require(store.workspaces.first { $0.id == resolvedWorkspaceID })
        #expect(workspace.macDeviceID == "mac-b")
        #expect(resolvedSurfaceOwnerID == resolvedWorkspaceID)
        #expect(store.workspaceID(matchingRemoteWorkspaceID: "shared", macDeviceID: "missing") == nil)
    }

    @Test func foregroundNotificationSuppressionRequiresExplicitSelection() {
        let store = MobileShellComposite.preview()
        store.signIn()
        let workspace = MobileWorkspacePreview(
            id: "row-a",
            macDeviceID: "mac-a",
            name: "First",
            terminals: [MobileTerminalPreview(id: "terminal-a", name: "a")]
        )
        store.setWorkspaceStatesForTesting([
            "mac-a": MacWorkspaceState(
                macDeviceID: "mac-a",
                workspaces: [workspace],
                status: .connected
            ),
        ], foregroundMacDeviceID: "mac-a")
        store.selectedWorkspaceID = nil

        #expect(store.selectedWorkspace?.id.rawValue == "row-a")
        #expect(!store.selectedWorkspaceMatches(remoteWorkspaceID: "row-a", macDeviceID: "mac-a"))

        store.selectedWorkspaceID = "row-a"
        #expect(store.selectedWorkspaceMatches(remoteWorkspaceID: "row-a", macDeviceID: "mac-a"))
    }

    @Test func secondaryUnavailableDowngradeKeepsRowsVisibleButInactive() {
        let store = MobileShellComposite.preview()
        store.signIn()
        let workspace = MobileWorkspacePreview(
            id: "secondary-row",
            macDeviceID: "mac-b",
            name: "Secondary",
            terminals: [MobileTerminalPreview(id: "terminal-b", name: "b")]
        )
        store.setWorkspaceStatesForTesting([
            "mac-b": MacWorkspaceState(
                macDeviceID: "mac-b",
                displayName: "Mac B",
                workspaces: [workspace],
                status: .connected
            ),
        ], foregroundMacDeviceID: nil)

        store.markSecondaryMacUnavailableForTesting("mac-b")

        let downgraded = store.workspaces.first { $0.rpcWorkspaceID.rawValue == "secondary-row" }
        #expect(downgraded?.macConnectionStatus == .unavailable)
        #expect(downgraded?.name == "Secondary")
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
