import CMUXMobileCore
import CmuxMobileBrowserStream
import CmuxMobilePairedMac
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Observation
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
    @Test func userRetryCoalescesWhileReconnectIsAlreadyInFlight() async {
        let store = MobileShellComposite.preview()
        store.isReconnectingStoredMac = true
        store.didFinishStoredMacReconnectAttempt = false

        let retryStarted = await store.retryActiveMacReconnect(stackUserID: "user-1")
        #expect(!retryStarted)
        #expect(store.isReconnectingStoredMac)
        #expect(!store.didFinishStoredMacReconnectAttempt)
    }

    @Test func explicitPairingReleasesSupersededStoredReconnectState() {
        let store = MobileShellComposite.preview()
        store.isReconnectingStoredMac = true
        store.didFinishStoredMacReconnectAttempt = false
        store.pairingCode = "preview-host"

        store.connectPreviewHost()

        #expect(!store.isReconnectingStoredMac)
    }

    @Test func macSurfaceSelectionIsExplicitAndIndependentFromTerminalSelection() {
        let store = MobileShellComposite.preview()
        let terminal = MobileTerminalPreview(id: "terminal", name: "Shell")
        let surface = MobileSurfacePreview(id: "surface", kind: .markdown, title: "README")
        let first = MobileWorkspacePreview(
            id: "first", name: "First", terminals: [terminal], surfaces: [surface]
        )
        let second = MobileWorkspacePreview(
            id: "second", name: "Second", terminals: [MobileTerminalPreview(id: "other", name: "Other")]
        )
        store.replaceForegroundWorkspaceState([first, second])
        store.selectedWorkspaceID = first.id
        #expect(store.selectedMacSurfaceID == nil)
        let terminalSelection = store.selectedTerminalID
        store.selectMacSurface(surface.id)
        #expect(store.selectedMacSurfaceID == surface.id)
        #expect(store.selectedTerminalID == terminalSelection)
        store.selectedWorkspaceID = second.id
        #expect(store.selectedMacSurfaceID == nil)
    }

    @Test func identicalForegroundStateDoesNotInvalidateWorkspaceList() async {
        let store = MobileShellComposite.preview()
        let workspace = MobileWorkspacePreview(
            id: "workspace-stable",
            name: "Stable",
            terminals: [MobileTerminalPreview(id: "terminal-stable", name: "stable")]
        )
        store.replaceForegroundWorkspaceState([workspace])
        let topologyVersion = store.workspaceTopologyVersion

        await confirmation("identical workspace state stays quiet", expectedCount: 0) {
            didChange in
            withObservationTracking {
                _ = store.workspaces
                _ = store.workspaceGroups
                _ = store.workspaceTopologyVersion
            } onChange: {
                didChange()
            }

            store.replaceForegroundWorkspaceState([workspace])
        }

        #expect(store.workspaceTopologyVersion == topologyVersion)
    }

    @Test func remoteRefreshPreservesOnlyForegroundViewportFit() throws {
        let store = MobileShellComposite.preview()
        let foregroundFit = MobileTerminalViewportFit(
            effective: MobileTerminalViewportSize(columns: 80, rows: 24),
            client: MobileTerminalViewportSize(columns: 100, rows: 30),
            isCurrentClientLimiting: true
        )
        let secondaryFit = MobileTerminalViewportFit(
            effective: MobileTerminalViewportSize(columns: 40, rows: 12),
            client: nil,
            isCurrentClientLimiting: false
        )
        store.setWorkspaceStatesForTesting([
            "mac-a": MacWorkspaceState(
                macDeviceID: "mac-a",
                workspaces: [MobileWorkspacePreview(
                    id: "shared",
                    macDeviceID: "mac-a",
                    name: "Foreground",
                    terminals: [MobileTerminalPreview(
                        id: "terminal-shared",
                        name: "old",
                        viewportFit: foregroundFit
                    )]
                )],
                status: .connected
            ),
            "mac-b": MacWorkspaceState(
                macDeviceID: "mac-b",
                workspaces: [MobileWorkspacePreview(
                    id: "shared",
                    macDeviceID: "mac-b",
                    name: "Secondary",
                    terminals: [MobileTerminalPreview(
                        id: "terminal-shared",
                        name: "other",
                        viewportFit: secondaryFit
                    )]
                )],
                status: .connected
            ),
        ], foregroundMacDeviceID: "mac-a")
        let response = try MobileSyncWorkspaceListResponse.decode(Data(#"""
        {
          "workspaces": [{
            "id": "shared",
            "title": "Refreshed",
            "is_selected": true,
            "terminals": [
              {"id": "terminal-shared", "title": "updated", "is_focused": true},
              {"id": "terminal-new", "title": "new", "is_focused": false}
            ]
          }],
          "groups": []
        }
        """#.utf8))

        store.applyRemoteWorkspaceList(response)

        let refreshed = try #require(store.workspaces.first { $0.macDeviceID == "mac-a" })
        #expect(refreshed.name == "Refreshed")
        #expect(refreshed.terminals.first?.viewportFit == foregroundFit)
        #expect(refreshed.terminals.last?.viewportFit == nil)
    }

    @Test func remoteRefreshMissingGroupFieldPreservesGroupHeaders() throws {
        let store = groupedForegroundStore()
        let response = try MobileSyncWorkspaceListResponse.decode(Data(#"""
        {
          "workspaces": [
            {
              "id": "anchor",
              "title": "Anchor",
              "is_selected": true,
              "group_id": "group-a",
              "terminals": []
            },
            {
              "id": "member",
              "title": "Member",
              "is_selected": false,
              "group_id": "group-a",
              "terminals": []
            }
          ]
        }
        """#.utf8))

        store.applyRemoteWorkspaceList(response)

        #expect(store.workspaceGroups.map(\.id.rawValue) == ["group-a"])
        #expect(store.workspaceGroups.first?.name == "Overnight")
        #expect(store.workspaces.map(\.groupID?.rawValue) == ["group-a", "group-a"])
    }

    @Test func remoteRefreshEmptyGroupMetadataWithGroupedRowsPreservesGroupHeaders() {
        let store = groupedForegroundStore()

        store.applyRemoteWorkspaceList(MobileSyncWorkspaceListResponse(
            workspaces: [
                workspaceListWorkspace(
                    id: "anchor",
                    title: "Anchor",
                    groupID: "group-a",
                    isSelected: true
                ),
                workspaceListWorkspace(
                    id: "member",
                    title: "Member",
                    groupID: "group-a"
                ),
            ],
            groups: [],
            createdWorkspaceID: nil,
            createdTerminalID: nil
        ))

        #expect(store.workspaceGroups.map(\.id.rawValue) == ["group-a"])
        #expect(store.workspaceGroups.first?.name == "Overnight")
        #expect(store.workspaces.map(\.groupID?.rawValue) == ["group-a", "group-a"])
    }

    @Test func disconnectedEmptyRefreshPreservesGroupHeaders() {
        let store = groupedForegroundStore()
        store.connectionState = .disconnected
        store.macConnectionStatus = .unavailable

        store.applyRemoteWorkspaceList(MobileSyncWorkspaceListResponse(
            workspaces: [],
            groups: [],
            createdWorkspaceID: nil,
            createdTerminalID: nil
        ))

        #expect(store.workspaceGroups.map(\.id.rawValue) == ["group-a"])
        #expect(store.workspaceGroups.first?.name == "Overnight")
    }

    @Test func connectedEmptyAuthoritativeRefreshCanClearGroupHeaders() {
        let store = groupedForegroundStore()

        store.applyRemoteWorkspaceList(MobileSyncWorkspaceListResponse(
            workspaces: [],
            groups: [],
            createdWorkspaceID: nil,
            createdTerminalID: nil
        ))

        #expect(store.workspaces.isEmpty)
        #expect(store.workspaceGroups.isEmpty)
    }

    @Test func connectedUngroupedRefreshCanClearGroupHeaders() {
        let store = groupedForegroundStore()

        store.applyRemoteWorkspaceList(MobileSyncWorkspaceListResponse(
            workspaces: [
                workspaceListWorkspace(
                    id: "anchor",
                    title: "Anchor",
                    isSelected: true
                ),
                workspaceListWorkspace(id: "member", title: "Member"),
            ],
            groups: [],
            createdWorkspaceID: nil,
            createdTerminalID: nil
        ))

        #expect(store.workspaceGroups.isEmpty)
        #expect(store.workspaces.map(\.groupID?.rawValue) == [String?](repeating: nil, count: 2))
    }

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

    @Test func signOutReturnsToSignInStateWithNoWorkspaces() {
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
        // No placeholder workspaces survive sign-out: the next session starts
        // from an empty list, not the `PreviewMobileHost` fixtures.
        #expect(store.selectedWorkspace == nil)
        #expect(store.workspaces.isEmpty)
        #expect(store.workspaceGroups.isEmpty)
    }

    @Test func networkChangeKeepsLegacyNoStoreConnectionAvailable() throws {
        let store = MobileShellComposite.preview()
        store.signIn()
        store.pairingCode = "debug"
        store.connectPreviewHost()
        let route = try hostPortRoute(
            kind: .debugLoopback,
            host: "127.0.0.1",
            port: CmxMobileDefaults.defaultHostPort
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace-main",
            terminalID: "terminal-main",
            macDeviceID: "legacy-mac",
            macDisplayName: "Legacy Mac",
            routes: [route],
            expiresAt: Date(timeIntervalSince1970: 86_400)
        )
        store.remoteClient = MobileCoreRPCClient(
            runtime: PairingDeadlineRuntime(),
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )

        store.recoverMobileConnection(trigger: .networkChange)

        #expect(store.connectionState == .connected)
        #expect(store.macConnectionStatus == .reconnecting)
        #expect(!store.connectionRecoveryFailed)
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

    @Test func teamChangeDoesNotStartACompetingStoredMacReconnect() async throws {
        let team = MutableTeamID("team-a")
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "team-a": [try Self.pairedMac(id: "mac-a", teamID: "team-a")],
                "team-b": [try Self.pairedMac(id: "mac-b", teamID: "team-b")],
            ],
            blockedTeams: ["team-a"]
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { await team.value },
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )

        let staleReconnect = Task {
            await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")
        }
        await pairedStore.waitUntilLoadStarted(teamID: "team-a")

        await team.set("team-b")
        store.currentTeamDidChange()
        await pairedStore.release(teamID: "team-a")
        _ = await staleReconnect.value
        for _ in 0..<10 { await Task.yield() }

        // Account-scope invalidation must not own a transport dial. The app
        // root's startup coordinator is the single owner that decides whether
        // an injected attach or saved-Mac restore runs next.
        #expect(!(await pairedStore.didStartLoad(teamID: "team-b")))
    }

    @Test func repeatedTeamChangeCancelsOwnedReconnectTask() async throws {
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: [:],
            blockedTeams: []
        )
        await pairedStore.gateBackupCancellation(call: 1)
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )

        store.currentTeamDidChange()
        await pairedStore.waitUntilBackupCancellationStarted(call: 1)
        store.currentTeamDidChange()
        await pairedStore.waitUntilBackupCancellationStarted(call: 2)
        await pairedStore.releaseBackupCancellation(call: 1)

        #expect(try await pollUntil {
            await pairedStore.backupCancellationWasCancelled(call: 1) != nil
        })
        #expect(await pairedStore.backupCancellationWasCancelled(call: 1) == true)
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

    @Test func createTerminalRemainsSelectedWhileItStarts() throws {
        let store = MobileShellComposite.preview()
        store.signIn()
        store.pairingCode = "debug"
        store.connectPreviewHost()

        store.createTerminal()
        let created = try #require(store.selectedTerminalID)
        let refreshedWorkspace = MobileWorkspacePreview(
            id: "workspace-main",
            name: "cmux",
            terminals: [
                MobileTerminalPreview(id: "terminal-build", name: "Build", isReady: true),
                MobileTerminalPreview(id: created, name: "Terminal 4", isReady: false),
            ]
        )

        store.replaceForegroundWorkspaceState([refreshedWorkspace])

        #expect(store.selectedTerminalID == created)
    }

    @Test func createTerminalFallsBackWhenCreatedTerminalDisappears() throws {
        let store = MobileShellComposite.preview()
        store.signIn()
        store.pairingCode = "debug"
        store.connectPreviewHost()

        store.createTerminal()
        let created = try #require(store.selectedTerminalID)
        store.replaceForegroundWorkspaceState([
            MobileWorkspacePreview(
                id: "workspace-main",
                name: "cmux",
                terminals: [MobileTerminalPreview(id: "terminal-build", name: "Build", isReady: true)]
            )
        ])

        #expect(store.selectedTerminalID == "terminal-build")
        #expect(store.selectedTerminalID != created)
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

    @Test func reopeningWorkspaceRestoresLastOpenedTerminalTab() {
        let store = MobileShellComposite.preview()
        store.signIn()
        let workspaceA = MobileWorkspacePreview(
            id: "ws-a",
            name: "A",
            terminals: [
                MobileTerminalPreview(id: "a1", name: "First", isFocused: true),
                MobileTerminalPreview(id: "a2", name: "Second"),
            ]
        )
        let workspaceB = MobileWorkspacePreview(
            id: "ws-b",
            name: "B",
            terminals: [MobileTerminalPreview(id: "b1", name: "Other")]
        )
        store.replaceForegroundWorkspaceState([workspaceA, workspaceB])
        store.selectedWorkspaceID = workspaceA.id
        #expect(store.selectedTerminalID?.rawValue == "a1")

        store.selectTerminalFromChrome("a2")
        store.selectedWorkspaceID = workspaceB.id
        #expect(store.selectedTerminalID?.rawValue == "b1")

        store.selectedWorkspaceID = workspaceA.id

        // Reopening the workspace shows the tab the user last opened there,
        // not the Mac-focused fallback.
        #expect(store.selectedTerminalID?.rawValue == "a2")
    }

    @Test func reopeningWorkspaceRestoresLastOpenedMacSurfaceTab() {
        let store = MobileShellComposite.preview()
        store.signIn()
        let workspaceA = MobileWorkspacePreview(
            id: "ws-a",
            name: "A",
            terminals: [MobileTerminalPreview(id: "a1", name: "Shell", isFocused: true)],
            surfaces: [MobileSurfacePreview(id: "s1", kind: .markdown, title: "README")]
        )
        let workspaceB = MobileWorkspacePreview(
            id: "ws-b",
            name: "B",
            terminals: [MobileTerminalPreview(id: "b1", name: "Other")]
        )
        store.replaceForegroundWorkspaceState([workspaceA, workspaceB])
        store.selectedWorkspaceID = workspaceA.id
        #expect(store.selectedTerminalID?.rawValue == "a1")

        store.selectMacSurface("s1")
        store.selectedWorkspaceID = workspaceB.id
        #expect(store.selectedMacSurfaceID == nil)

        store.selectedWorkspaceID = workspaceA.id

        // The last opened tab in ws-a was the Mac surface, so reopening the
        // workspace shows it again instead of falling back to the terminal.
        #expect(store.selectedMacSurfaceID?.rawValue == "s1")
    }

    @Test func reopeningWorkspaceFallsBackWhenLastOpenedTabIsGone() {
        let store = MobileShellComposite.preview()
        store.signIn()
        let workspaceA = MobileWorkspacePreview(
            id: "ws-a",
            name: "A",
            terminals: [
                MobileTerminalPreview(id: "a1", name: "First", isFocused: true),
                MobileTerminalPreview(id: "a2", name: "Second"),
            ]
        )
        let workspaceB = MobileWorkspacePreview(
            id: "ws-b",
            name: "B",
            terminals: [MobileTerminalPreview(id: "b1", name: "Other")]
        )
        store.replaceForegroundWorkspaceState([workspaceA, workspaceB])
        store.selectedWorkspaceID = workspaceA.id
        store.selectTerminalFromChrome("a2")
        store.selectedWorkspaceID = workspaceB.id

        // The remembered tab is closed on the Mac while the user is away.
        let workspaceAWithoutA2 = MobileWorkspacePreview(
            id: "ws-a",
            name: "A",
            terminals: [MobileTerminalPreview(id: "a1", name: "First", isFocused: true)]
        )
        store.replaceForegroundWorkspaceState([workspaceAWithoutA2, workspaceB])
        store.selectedWorkspaceID = workspaceA.id

        #expect(store.selectedTerminalID?.rawValue == "a1")
    }

    @Test func reopeningSameWorkspaceRestoresBrowserStreamTab() async {
        let browserStreams = BrowserStreamStore()
        let store = MobileShellComposite.preview(browserStreamEvents: browserStreams)
        store.signIn()
        let workspaceB = MobileWorkspacePreview(
            id: "ws-b",
            name: "Beta",
            terminals: [MobileTerminalPreview(id: "b1", name: "Shell", isFocused: true)],
            surfaces: [MobileSurfacePreview(id: "panel-1", kind: .browser, title: "Web")]
        )
        store.replaceForegroundWorkspaceState([workspaceB])
        store.selectedWorkspaceID = workspaceB.id
        browserStreams.replacePanels(in: "ws-b", with: [
            MobileBrowserPanelDescriptor(
                panelID: "panel-1", workspaceID: "ws-b", url: nil, title: "Web",
                pageWidth: 900, pageHeight: 600,
                canGoBack: false, canGoForward: false, isLoading: false
            ),
        ])

        // The user opens the browser stream tab from the picker.
        _ = browserStreams.activate(panelID: "panel-1", in: "ws-b")
        store.recordLastOpenedBrowserStreamTab(panelID: "panel-1", in: workspaceB.id)

        // Leaving the workspace unmounts the stream surface, which stops and
        // deactivates the stream (`onDisappear` in the detail view).
        browserStreams.deactivate(in: "ws-b")
        #expect(browserStreams.activeState(in: "ws-b") == nil)

        // Reopening the SAME workspace from the list remounts the detail with
        // an unchanged selection; only `openWorkspace` marks the open.
        await store.openWorkspace(workspaceB.id)

        #expect(browserStreams.activeState(in: "ws-b")?.id == "panel-1")
    }

    @Test func listRefreshWhileAwayDoesNotClobberBrowserStreamMemory() async {
        let browserStreams = BrowserStreamStore()
        let store = MobileShellComposite.preview(browserStreamEvents: browserStreams)
        store.signIn()
        let workspaceB = MobileWorkspacePreview(
            id: "ws-b",
            name: "Beta",
            terminals: [MobileTerminalPreview(id: "b1", name: "Shell", isFocused: true)],
            surfaces: [MobileSurfacePreview(id: "panel-1", kind: .browser, title: "Web")]
        )
        store.replaceForegroundWorkspaceState([workspaceB])
        store.selectedWorkspaceID = workspaceB.id
        browserStreams.replacePanels(in: "ws-b", with: [
            MobileBrowserPanelDescriptor(
                panelID: "panel-1", workspaceID: "ws-b", url: nil, title: "Web",
                pageWidth: 900, pageHeight: 600,
                canGoBack: false, canGoForward: false, isLoading: false
            ),
        ])
        _ = browserStreams.activate(panelID: "panel-1", in: "ws-b")
        store.recordLastOpenedBrowserStreamTab(panelID: "panel-1", in: workspaceB.id)
        browserStreams.deactivate(in: "ws-b")

        // While the user sits on the workspace list (selection retained, the
        // stream stopped), workspace list refreshes re-run the selection
        // synchronizer. That churn must not overwrite the remembered tab.
        store.replaceForegroundWorkspaceState([workspaceB])
        store.replaceForegroundWorkspaceState([workspaceB])

        await store.openWorkspace(workspaceB.id)
        #expect(browserStreams.activeState(in: "ws-b")?.id == "panel-1")
    }

    @Test func reopeningSameWorkspaceRestoresSimulatorStreamTab() async {
        let simulatorStreams = MobileSimulatorStreamStore()
        let store = MobileShellComposite.preview(simulatorStreamStore: simulatorStreams)
        store.signIn()
        let simulator = MobileSimulatorPanelDescriptor(
            panelID: "sim-1", workspaceID: "ws-b", title: "iPhone",
            selectedDeviceName: "iPhone 17", selectedDeviceState: "Booted",
            status: "ready", isReady: true,
            supportsTouch: true, supportsKeyboard: true,
            supportsHardwareButtons: true, supportsRotation: true
        )
        let workspaceB = MobileWorkspacePreview(
            id: "ws-b",
            name: "Beta",
            terminals: [MobileTerminalPreview(id: "b1", name: "Shell", isFocused: true)],
            simulators: [simulator]
        )
        store.replaceForegroundWorkspaceState([workspaceB])
        store.selectedWorkspaceID = workspaceB.id
        simulatorStreams.replaceSimulatorPanels(in: "ws-b", with: [simulator])
        _ = simulatorStreams.activate(panelID: "sim-1", in: "ws-b")
        store.recordLastOpenedSimulatorStreamTab(panelID: "sim-1", in: workspaceB.id)

        simulatorStreams.deactivate(in: "ws-b")
        #expect(simulatorStreams.activeState(in: "ws-b") == nil)

        await store.openWorkspace(workspaceB.id)
        #expect(simulatorStreams.activeState(in: "ws-b")?.id == "sim-1")
    }

    @Test func reopeningSameWorkspaceRestoresLocalBrowserTab() async {
        let store = MobileShellComposite.preview()
        store.signIn()
        let workspaceB = MobileWorkspacePreview(
            id: "ws-b",
            name: "Beta",
            terminals: [MobileTerminalPreview(id: "b1", name: "Shell", isFocused: true)]
        )
        store.replaceForegroundWorkspaceState([workspaceB])
        store.selectedWorkspaceID = workspaceB.id
        store.recordLastOpenedLocalBrowserTab(in: workspaceB.id)

        await store.openWorkspace(workspaceB.id)

        // The composite hands the phone-local browser reopen to the detail
        // view as a one-shot intent.
        #expect(store.consumeLocalBrowserTabRestore(for: workspaceB.id))
        #expect(!store.consumeLocalBrowserTabRestore(for: workspaceB.id))
    }

    @Test func explicitTerminalPickWinsOverPendingStreamRestore() async {
        let browserStreams = BrowserStreamStore()
        let store = MobileShellComposite.preview(browserStreamEvents: browserStreams)
        store.signIn()
        let workspaceB = MobileWorkspacePreview(
            id: "ws-b",
            name: "Beta",
            terminals: [
                MobileTerminalPreview(id: "b1", name: "Shell", isFocused: true),
                MobileTerminalPreview(id: "b2", name: "Second"),
            ],
            surfaces: [MobileSurfacePreview(id: "panel-1", kind: .browser, title: "Web")]
        )
        store.replaceForegroundWorkspaceState([workspaceB])
        store.selectedWorkspaceID = workspaceB.id
        store.recordLastOpenedBrowserStreamTab(panelID: "panel-1", in: workspaceB.id)
        // The stream panel is never discovered (Mac unreachable), so a reopen
        // keeps the restore armed. An explicit pick must disarm it and win.
        await store.openWorkspace(workspaceB.id)
        store.selectTerminalFromChrome("b2")

        browserStreams.replacePanels(in: "ws-b", with: [
            MobileBrowserPanelDescriptor(
                panelID: "panel-1", workspaceID: "ws-b", url: nil, title: "Web",
                pageWidth: 900, pageHeight: 600,
                canGoBack: false, canGoForward: false, isLoading: false
            ),
        ])
        store.refreshWorkspaceSelection()

        #expect(browserStreams.activeState(in: "ws-b") == nil)
        #expect(store.selectedTerminalID?.rawValue == "b2")
    }

    @Test func lastOpenedTabIsRestoredAcrossStoreInstances() {
        let suiteName = "MobileShellCompositeLastTabTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let workspaceA = MobileWorkspacePreview(
            id: "ws-a",
            name: "A",
            terminals: [
                MobileTerminalPreview(id: "a1", name: "First", isFocused: true),
                MobileTerminalPreview(id: "a2", name: "Second"),
            ]
        )
        let workspaceB = MobileWorkspacePreview(
            id: "ws-b",
            name: "B",
            terminals: [MobileTerminalPreview(id: "b1", name: "Other")]
        )

        let first = MobileShellComposite.preview(
            lastTabStore: MobileWorkspaceLastTabStore(defaults: defaults)
        )
        first.signIn()
        first.replaceForegroundWorkspaceState([workspaceA, workspaceB])
        first.selectedWorkspaceID = workspaceA.id
        first.selectTerminalFromChrome("a2")

        // A relaunch constructs a fresh store over the same defaults; opening
        // the workspace restores the tab the previous session last opened.
        let second = MobileShellComposite.preview(
            lastTabStore: MobileWorkspaceLastTabStore(defaults: defaults)
        )
        second.signIn()
        second.replaceForegroundWorkspaceState([workspaceA, workspaceB])
        second.selectedWorkspaceID = workspaceA.id
        #expect(second.selectedTerminalID?.rawValue == "a2")
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

    @Test func deeplinkWorkspaceResolutionSeparatesSiblingBuilds() throws {
        let store = MobileShellComposite.preview()
        store.signIn()
        var stable = MobileWorkspacePreview(
            id: "shared",
            macDeviceID: "mac-a",
            name: "Stable",
            terminals: [MobileTerminalPreview(id: "terminal-shared", name: "stable")]
        )
        stable.macInstanceTag = "stable"
        var nightly = MobileWorkspacePreview(
            id: "shared",
            macDeviceID: "mac-a",
            name: "Nightly",
            terminals: [MobileTerminalPreview(id: "terminal-shared", name: "nightly")]
        )
        nightly.macInstanceTag = "nightly"
        store.setWorkspaceStatesForTesting([
            MobilePairedMac.pairingID(macDeviceID: "mac-a", instanceTag: "stable"):
                MacWorkspaceState(
                    macDeviceID: "mac-a", instanceTag: "stable",
                    workspaces: [stable], status: .connected
                ),
            MobilePairedMac.pairingID(macDeviceID: "mac-a", instanceTag: "nightly"):
                MacWorkspaceState(
                    macDeviceID: "mac-a", instanceTag: "nightly",
                    workspaces: [nightly], status: .connected
                ),
        ], foregroundMacDeviceID: "mac-a")

        let stableID = try #require(store.workspaceID(
            matchingRemoteWorkspaceID: "shared",
            macDeviceID: "mac-a",
            instanceTag: "stable"
        ))
        let nightlyID = try #require(store.workspaceID(
            containingSurfaceID: "terminal-shared",
            macDeviceID: "mac-a",
            instanceTag: "nightly"
        ))

        #expect(stableID != nightlyID)
        #expect(store.workspaces.first { $0.id == stableID }?.macInstanceTag == "stable")
        #expect(store.workspaces.first { $0.id == nightlyID }?.macInstanceTag == "nightly")
        #expect(store.workspaceID(
            matchingRemoteWorkspaceID: "shared",
            macDeviceID: "mac-a"
        ) == nil)
        #expect(store.workspaceID(
            containingSurfaceID: "terminal-shared",
            macDeviceID: "mac-a"
        ) == nil)
    }

    @Test func ownerlessDeeplinkCannotBorrowTheOnlyTaggedBuild() {
        var nightly = MobileWorkspacePreview(
            id: "nightly-row",
            macDeviceID: "mac-a",
            name: "Nightly",
            terminals: [MobileTerminalPreview(id: "terminal", name: "nightly")]
        )
        nightly.macInstanceTag = "nightly"
        nightly.remoteWorkspaceID = "workspace"
        let store = MobileShellComposite(workspaces: [nightly])

        #expect(store.workspaceID(matchingRemoteWorkspaceID: "workspace") == nil)
        #expect(store.workspaceID(containingSurfaceID: "terminal") == nil)
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

    @Test func macScopedSelectionDoesNotMatchAnUnownedWorkspace() {
        let workspace = MobileWorkspacePreview(
            id: "unowned-row",
            name: "Unowned",
            terminals: [MobileTerminalPreview(id: "terminal", name: "unowned")]
        )
        let store = MobileShellComposite(workspaces: [workspace])
        store.selectedWorkspaceID = "unowned-row"

        #expect(!store.selectedWorkspaceMatches(
            remoteWorkspaceID: "unowned-row",
            macDeviceID: "mac-a"
        ))
    }

    @Test func legacyComputerPriorityMigratesToBuildScopedPairings() async throws {
        let suiteName = "computer-priority-migration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            Data(#"{"mode":"computerPriority","computerPriority":["mac-a"]}"#.utf8),
            forKey: MobileWorkspaceSortStore.defaultsKey
        )
        let sortStore = MobileWorkspaceSortStore(defaults: defaults)
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "team-a": [
                    MobilePairedMac(
                        macDeviceID: "mac-a", displayName: "Mac A", routes: [],
                        createdAt: Date(timeIntervalSince1970: 1),
                        lastSeenAt: Date(timeIntervalSince1970: 4), isActive: false,
                        stackUserID: "user-1", teamID: "team-a"
                    ),
                    MobilePairedMac(
                        macDeviceID: "mac-a", displayName: "Mac A", routes: [],
                        createdAt: Date(timeIntervalSince1970: 1),
                        lastSeenAt: Date(timeIntervalSince1970: 2), isActive: false,
                        stackUserID: "user-1", teamID: "team-a", instanceTag: "stable"
                    ),
                    MobilePairedMac(
                        macDeviceID: "mac-a", displayName: "Mac A", routes: [],
                        createdAt: Date(timeIntervalSince1970: 1),
                        lastSeenAt: Date(timeIntervalSince1970: 3), isActive: false,
                        stackUserID: "user-1", teamID: "team-a", instanceTag: "nightly"
                    ),
                ],
            ],
            blockedTeams: []
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" },
            workspaceSortStore: sortStore
        )

        await store.loadPairedMacs()

        #expect(store.workspaceComputerPriority == [
            MobilePairedMac.pairingID(macDeviceID: "mac-a", instanceTag: nil),
            MobilePairedMac.pairingID(macDeviceID: "mac-a", instanceTag: "nightly"),
            MobilePairedMac.pairingID(macDeviceID: "mac-a", instanceTag: "stable"),
        ])
        #expect(MobileWorkspaceSortStore(defaults: defaults).computerPriority == store.workspaceComputerPriority)
    }

    @Test func foregroundWorkspaceChangesRetainAnonymousRows() {
        let anonymous = MobileWorkspacePreview(
            id: "anonymous", name: "Anonymous", terminals: []
        )
        var owned = MobileWorkspacePreview(
            id: "owned", macDeviceID: "mac-a", name: "Owned", terminals: []
        )
        owned.macInstanceTag = "stable"
        let store = MobileShellComposite(workspaces: [anonymous, owned])
        store.foregroundMacDeviceID = "mac-a"
        store.activeMacInstanceTag = "stable"

        #expect(Set(store.foregroundWorkspaceChangesIDs) == ["anonymous", "owned"])
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

@MainActor
private func groupedForegroundStore() -> CMUXMobileShellStore {
    let store = MobileShellComposite.preview()
    store.signIn()
    store.pairingCode = "debug"
    store.connectPreviewHost()
    store.replaceForegroundWorkspaceState([
        MobileWorkspacePreview(
            id: "anchor",
            name: "Anchor",
            groupID: "group-a",
            terminals: []
        ),
        MobileWorkspacePreview(
            id: "member",
            name: "Member",
            groupID: "group-a",
            terminals: []
        ),
    ], groups: [
        MobileWorkspaceGroupPreview(
            id: "group-a",
            name: "Overnight",
            anchorWorkspaceID: "anchor"
        ),
    ])
    return store
}

private func workspaceListWorkspace(
    id: String,
    title: String,
    groupID: String? = nil,
    isSelected: Bool = false
) -> MobileSyncWorkspaceListResponse.Workspace {
    MobileSyncWorkspaceListResponse.Workspace(
        id: id,
        windowID: nil,
        title: title,
        currentDirectory: nil,
        isSelected: isSelected,
        isPinned: nil,
        groupID: groupID,
        preview: nil,
        previewAt: nil,
        lastActivityAt: nil,
        hasUnread: nil,
        terminals: []
    )
}
