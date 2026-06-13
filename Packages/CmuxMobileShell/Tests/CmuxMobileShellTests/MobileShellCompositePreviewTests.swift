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
        // Group sections are account-scoped: the previous account's group
        // names must not survive sign-out into the next session.
        store.workspaceGroups = [
            MobileWorkspaceGroupPreview(
                id: "group-1",
                name: "previous account group",
                isCollapsed: false,
                isPinned: false,
                anchorWorkspaceID: "workspace-main"
            )
        ]

        store.signOut()

        #expect(store.phase == .signIn)
        #expect(store.connectionState == .disconnected)
        #expect(store.connectedHostName.isEmpty)
        #expect(store.selectedWorkspace?.name == "cmux")
        #expect(store.workspaceGroups.isEmpty)
    }

    @Test func collapsedGroupSelectionMovesHiddenMemberToAnchor() {
        let store = MobileShellComposite(
            workspaces: groupSelectionWorkspaces(),
            draftStore: InMemoryTerminalDraftStore()
        )
        store.workspaceGroups = [
            MobileWorkspaceGroupPreview(
                id: "group-1",
                name: "Feature",
                isCollapsed: true,
                isPinned: false,
                anchorWorkspaceID: "workspace-anchor"
            )
        ]
        store.selectedWorkspaceID = "workspace-child"
        store.selectedTerminalID = "terminal-child"

        store.reconcileSelectedWorkspaceWithVisibleGroupState()

        #expect(store.selectedWorkspaceID == "workspace-anchor")
        #expect(store.selectedTerminalID == "terminal-anchor")
    }

    @Test func expandedGroupSelectionKeepsMemberSelected() {
        let store = MobileShellComposite(
            workspaces: groupSelectionWorkspaces(),
            draftStore: InMemoryTerminalDraftStore()
        )
        store.workspaceGroups = [
            MobileWorkspaceGroupPreview(
                id: "group-1",
                name: "Feature",
                isCollapsed: false,
                isPinned: false,
                anchorWorkspaceID: "workspace-anchor"
            )
        ]
        store.selectedWorkspaceID = "workspace-child"
        store.selectedTerminalID = "terminal-child"

        store.reconcileSelectedWorkspaceWithVisibleGroupState()

        #expect(store.selectedWorkspaceID == "workspace-child")
        #expect(store.selectedTerminalID == "terminal-child")
    }

    @Test func createWorkspaceInGroupAddsGroupedWorkspaceAndExpandsGroup() {
        let store = MobileShellComposite(
            workspaces: groupSelectionWorkspaces(),
            draftStore: InMemoryTerminalDraftStore()
        )
        store.workspaceGroups = [
            MobileWorkspaceGroupPreview(
                id: "group-1",
                name: "Feature",
                isCollapsed: true,
                isPinned: false,
                anchorWorkspaceID: "workspace-anchor"
            )
        ]

        store.createWorkspace(inGroup: "group-1")

        let created = store.workspaces.last
        #expect(created?.groupID == "group-1")
        #expect(store.workspaceGroups.first?.isCollapsed == false)
        #expect(store.selectedWorkspaceID == created?.id)
        #expect(store.selectedTerminalID == created?.terminals.first?.id)
    }

    @Test func scopedGroupWorkspaceResponsePreservesOtherWindows() throws {
        let store = MobileShellComposite(
            workspaces: [
                testWorkspace("workspace-anchor", windowID: "window-group", name: "Feature", groupID: "group-1", terminal: "terminal-anchor"),
                testWorkspace("workspace-child", windowID: "window-group", name: "Implementation", groupID: "group-1", terminal: "terminal-child"),
                testWorkspace("workspace-bottom", windowID: "window-group", name: "Bottom", terminal: "terminal-bottom"),
                testWorkspace("workspace-stale-anchor", windowID: "window-group", name: "Stale", groupID: "group-stale", terminal: "terminal-stale"),
                testWorkspace("workspace-other-window", windowID: "window-other", name: "Other window", groupID: "group-other", terminal: "terminal-other"),
            ],
            draftStore: InMemoryTerminalDraftStore()
        )
        store.workspaceGroups = [
            MobileWorkspaceGroupPreview(
                id: "group-1",
                name: "Feature",
                isCollapsed: true,
                isPinned: false,
                anchorWorkspaceID: "workspace-anchor"
            ),
            MobileWorkspaceGroupPreview(
                id: "group-stale",
                name: "Stale",
                isCollapsed: false,
                isPinned: false,
                anchorWorkspaceID: "workspace-stale-anchor"
            ),
            MobileWorkspaceGroupPreview(
                id: "group-other",
                name: "Other window group",
                isCollapsed: false,
                isPinned: false,
                anchorWorkspaceID: "workspace-other-window"
            ),
        ]

        let response = try mobileWorkspaceListResponse(
            """
            {
              "created_workspace_id": "workspace-created",
              "workspaces": [
                {
                  "id": "workspace-anchor",
                  "window_id": "window-group",
                  "title": "Feature",
                  "current_directory": null,
                  "is_selected": false,
                  "is_pinned": false,
                  "group_id": "group-1",
                  "terminals": [
                    {
                      "id": "terminal-anchor",
                      "title": "anchor",
                      "current_directory": null,
                      "is_focused": true,
                      "is_ready": true
                    }
                  ]
                },
                {
                  "id": "workspace-created",
                  "window_id": "window-group",
                  "title": "New workspace",
                  "current_directory": null,
                  "is_selected": true,
                  "is_pinned": false,
                  "group_id": "group-1",
                  "terminals": [
                    {
                      "id": "terminal-created",
                      "title": "terminal",
                      "current_directory": null,
                      "is_focused": true,
                      "is_ready": true
                    }
                  ]
                },
                {
                  "id": "workspace-child",
                  "window_id": "window-group",
                  "title": "Implementation",
                  "current_directory": null,
                  "is_selected": false,
                  "is_pinned": false,
                  "group_id": "group-1",
                  "terminals": [
                    {
                      "id": "terminal-child",
                      "title": "child",
                      "current_directory": null,
                      "is_focused": true,
                      "is_ready": true
                    }
                  ]
                },
                {
                  "id": "workspace-bottom",
                  "window_id": "window-group",
                  "title": "Bottom",
                  "current_directory": null,
                  "is_selected": false,
                  "is_pinned": false,
                  "group_id": null,
                  "terminals": [
                    {
                      "id": "terminal-bottom",
                      "title": "bottom",
                      "current_directory": null,
                      "is_focused": true,
                      "is_ready": true
                    }
                  ]
                }
              ],
              "groups": [
                {
                  "id": "group-1",
                  "name": "Feature",
                  "is_collapsed": false,
                  "is_pinned": false,
                  "anchor_workspace_id": "workspace-anchor"
                }
              ]
            }
            """
        )

        store.applyRemoteWorkspaceList(
            response,
            mergeExistingWorkspaces: true,
            mergeWorkspaceGroups: true
        )

        #expect(store.workspaces.map(\.id.rawValue).contains("workspace-other-window"))
        #expect(store.workspaceGroups.map(\.id.rawValue).contains("group-other"))
        #expect(!store.workspaceGroups.map(\.id.rawValue).contains("group-stale"))
        #expect(store.workspaces.map(\.id.rawValue) == [
            "workspace-anchor",
            "workspace-created",
            "workspace-child",
            "workspace-bottom",
            "workspace-other-window",
        ])
        let updatedGroup = try #require(store.workspaceGroups.first { $0.id == "group-1" })
        #expect(updatedGroup.isCollapsed == false)
        let created = try #require(store.workspaces.first { $0.id == "workspace-created" })
        #expect(created.groupID == "group-1")
        #expect(created.terminals.first?.id == "terminal-created")
        let listItemIDs = MobileWorkspaceListItem.items(
            workspaces: store.workspaces,
            groups: store.workspaceGroups
        ).map { item in
            switch item {
            case .groupHeader(let group, _):
                "group.\(group.id.rawValue)"
            case .workspace(let workspace, _):
                "workspace.\(workspace.id.rawValue)"
            }
        }
        #expect(listItemIDs.prefix(4) == [
            "group.group-1",
            "workspace.workspace-created",
            "workspace.workspace-child",
            "workspace.workspace-bottom",
        ])
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

private func groupSelectionWorkspaces() -> [MobileWorkspacePreview] {
    [
        MobileWorkspacePreview(
            id: "workspace-anchor",
            name: "Feature",
            groupID: "group-1",
            terminals: [
                MobileTerminalPreview(id: "terminal-anchor", name: "anchor")
            ]
        ),
        MobileWorkspacePreview(
            id: "workspace-child",
            name: "Implementation",
            groupID: "group-1",
            terminals: [
                MobileTerminalPreview(id: "terminal-child", name: "child")
            ]
        ),
    ]
}

private func testWorkspace(
    _ id: String,
    windowID: String? = nil,
    name: String,
    groupID: String? = nil,
    terminal: String
) -> MobileWorkspacePreview {
    MobileWorkspacePreview(
        id: MobileWorkspacePreview.ID(rawValue: id),
        windowID: windowID,
        name: name,
        groupID: groupID.map { MobileWorkspaceGroupPreview.ID(rawValue: $0) },
        terminals: [
            MobileTerminalPreview(id: MobileTerminalPreview.ID(rawValue: terminal), name: terminal)
        ]
    )
}

private func mobileWorkspaceListResponse(_ json: String) throws -> MobileSyncWorkspaceListResponse {
    try MobileSyncWorkspaceListResponse.decode(Data(json.utf8))
}
