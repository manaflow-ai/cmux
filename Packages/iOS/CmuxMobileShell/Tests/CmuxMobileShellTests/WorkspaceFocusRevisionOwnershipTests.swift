import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Test func currentTeamChangeKeepsForegroundFocusRevisionsAndEvictsSecondaryOwners() {
    let store = MobileShellComposite.preview()
    let foregroundMacID = "foreground-mac"
    let secondaryMacID = "secondary-mac"
    store.setWorkspaceStatesForTesting(
        [
            foregroundMacID: MacWorkspaceState(
                macDeviceID: foregroundMacID,
                workspaces: [MobileWorkspacePreview(id: "foreground-workspace", name: "Foreground", terminals: [])]
            ),
            secondaryMacID: MacWorkspaceState(
                macDeviceID: secondaryMacID,
                workspaces: [MobileWorkspacePreview(id: "secondary-workspace", name: "Secondary", terminals: [])]
            ),
        ],
        foregroundMacDeviceID: foregroundMacID
    )
    store.workspaceFocusEventRevisionsByMac = [
        foregroundMacID: ["foreground-workspace": 3],
        secondaryMacID: ["secondary-workspace": 4],
    ]
    store.workspaceFocusEventRevision = 4

    store.currentTeamDidChange()

    #expect(store.workspaceFocusEventRevisionsByMac[foregroundMacID] == ["foreground-workspace": 3])
    #expect(store.workspaceFocusEventRevisionsByMac[secondaryMacID] == nil)
    #expect(store.workspaceFocusEventRevision == 4)
}

@MainActor
@Test func secondaryDisappearanceEvictsItsFocusRevisionOwner() async throws {
    let router = RoutingHostRouter()
    let pairedMacStore = DelayedTeamPairedMacStore(recordsByTeam: ["team-a": []], blockedTeams: [])
    let store = makeRoutingMultiMacStore(router: router, pairedMacStore: pairedMacStore)
    let secondaryMacID = "vanished-secondary"
    try installSecondaryClient(on: store, macDeviceID: secondaryMacID, router: router)
    store.workspaceFocusEventRevisionsByMac[secondaryMacID] = ["workspace-old": 7]
    store.workspaceFocusEventRevision = 7

    await store.refreshSecondaryMacWorkspaces()

    #expect(store.secondaryMacSubscriptions[secondaryMacID] == nil)
    #expect(store.workspaceFocusEventRevisionsByMac[secondaryMacID] == nil)
    #expect(store.workspaceFocusEventRevision == 7)
}

@MainActor
@Test func foregroundIdentityAdoptionMaxMergesFocusRevisionsAndClearsOldOwner() {
    let store = MobileShellComposite.preview()
    let oldOwner = MobileShellComposite.foregroundAnonymousKey
    let adoptedOwner = "adopted-mac"
    store.setWorkspaceStatesForTesting(
        [
            oldOwner: MacWorkspaceState(
                macDeviceID: oldOwner,
                workspaces: [MobileWorkspacePreview(id: "workspace-shared", name: "Anonymous", terminals: [])]
            ),
            adoptedOwner: MacWorkspaceState(
                macDeviceID: adoptedOwner,
                workspaces: [MobileWorkspacePreview(id: "workspace-existing", name: "Existing", terminals: [])]
            ),
        ],
        foregroundMacDeviceID: nil
    )
    store.workspaceFocusEventRevision = 11
    store.workspaceFocusEventRevisionsByMac = [
        oldOwner: ["workspace-shared": 5, "workspace-old-only": 7],
        adoptedOwner: ["workspace-shared": 9, "workspace-target-only": 4],
    ]

    store.adoptForegroundMacIdentity(adoptedOwner)

    #expect(store.workspaceFocusEventRevisionsByMac[oldOwner] == nil)
    #expect(store.workspaceFocusEventRevisionsByMac[adoptedOwner] == [
        "workspace-shared": 9,
        "workspace-old-only": 7,
        "workspace-target-only": 4,
    ])
    #expect(store.workspaceFocusEventRevision == 11)
}

@MainActor
@Test func lateWorkspaceFocusEventCannotRestoreClosedTerminalTopology() throws {
    let survivorID = MobileTerminalPreview.ID(rawValue: "terminal-survivor")
    let survivorPaneID = MobilePanePreview.ID(rawValue: "pane-survivor")
    let workspace = MobileWorkspacePreview(
        id: "workspace-after-close",
        name: "After close",
        terminals: [
            MobileTerminalPreview(
                id: survivorID,
                name: "Survivor",
                paneID: survivorPaneID,
                isFocused: true
            ),
        ],
        panes: [
            MobilePanePreview(
                id: survivorPaneID,
                spatialIndex: 0,
                isFocused: true,
                terminalIDs: [survivorID]
            ),
        ],
        focusedPaneID: survivorPaneID,
        selectedTerminalID: survivorID
    )
    let store = MobileShellComposite(workspaces: [workspace])
    let lateEvent = try #require(MobileWorkspaceFocusEvent(payloadJSON: Data("""
    {"kind":"focus","workspace_id":"workspace-after-close","focused_pane_id":"pane-closed","selected_terminal_id":"terminal-closed"}
    """.utf8)))

    store.applyWorkspaceFocusEvent(lateEvent, macID: nil)

    let updated = try #require(store.workspaces.first)
    #expect(updated.focusedPaneID == survivorPaneID)
    #expect(updated.selectedTerminalID == survivorID)
    #expect(updated.panes.first?.isFocused == true)
    #expect(updated.terminals.first?.isFocused == true)
}

@MainActor
@Test func focusSnapshotDimensionsApplyNilAndValidValuesIndependently() throws {
    let workspace = MobileWorkspacePreview(
        id: "workspace-mixed-focus",
        name: "Mixed focus",
        terminals: [
            MobileTerminalPreview(id: "terminal-a", name: "A", paneID: "pane-a", isFocused: true),
            MobileTerminalPreview(id: "terminal-b", name: "B", paneID: "pane-b"),
        ],
        panes: [
            MobilePanePreview(id: "pane-a", spatialIndex: 0, isFocused: true, terminalIDs: ["terminal-a"]),
            MobilePanePreview(id: "pane-b", spatialIndex: 1, terminalIDs: ["terminal-b"]),
        ],
        focusedPaneID: "pane-a",
        selectedTerminalID: "terminal-a"
    )
    let store = MobileShellComposite(workspaces: [workspace])
    let event = try #require(MobileWorkspaceFocusEvent(payloadJSON: Data("""
    {"kind":"focus","workspace_id":"workspace-mixed-focus","focused_pane_id":null,"selected_terminal_id":"terminal-b"}
    """.utf8)))

    store.applyWorkspaceFocusEvent(event, macID: nil)

    let applied = try #require(store.workspaces.first)
    #expect(applied.focusedPaneID == nil)
    #expect(applied.panes.allSatisfy { !$0.isFocused })
    #expect(applied.selectedTerminalID == "terminal-b")
    #expect(applied.terminals.first(where: { $0.id == "terminal-b" })?.isFocused == true)

    var refreshed = workspace
    var existing = workspace
    existing.focusedPaneID = "pane-b"
    existing.panes[0].isFocused = false
    existing.panes[1].isFocused = true
    existing.selectedTerminalID = nil
    existing.terminals[0].isFocused = false
    refreshed.preserveFocusSnapshot(from: existing)

    #expect(refreshed.focusedPaneID == "pane-b")
    #expect(refreshed.panes.first(where: { $0.id == "pane-b" })?.isFocused == true)
    #expect(refreshed.selectedTerminalID == nil)
    #expect(refreshed.terminals.allSatisfy { !$0.isFocused })
}

@MainActor
@Test func unknownFocusEventDimensionsDoNotOverrideAuthoritativeListFocus() throws {
    let oldPaneID = MobilePanePreview.ID(rawValue: "pane-old")
    let oldTerminalID = MobileTerminalPreview.ID(rawValue: "terminal-old")
    let newPaneID = MobilePanePreview.ID(rawValue: "pane-new")
    let newTerminalID = MobileTerminalPreview.ID(rawValue: "terminal-new")
    let existing = MobileWorkspacePreview(
        id: "workspace-create-race",
        name: "Create race",
        terminals: [
            MobileTerminalPreview(id: oldTerminalID, name: "Old", paneID: oldPaneID, isFocused: true),
        ],
        panes: [
            MobilePanePreview(id: oldPaneID, spatialIndex: 0, isFocused: true, terminalIDs: [oldTerminalID]),
        ],
        focusedPaneID: oldPaneID,
        selectedTerminalID: oldTerminalID
    )
    let store = MobileShellComposite(workspaces: [existing])
    let listStartedAtFocusRevision = store.workspaceFocusRevisionSnapshot()
    let event = try #require(MobileWorkspaceFocusEvent(payloadJSON: Data("""
    {"kind":"focus","workspace_id":"workspace-create-race","focused_pane_id":"pane-new","selected_terminal_id":"terminal-new"}
    """.utf8)))

    store.applyWorkspaceFocusEvent(event, macID: nil)

    var authoritative = MobileWorkspacePreview(
        id: "workspace-create-race",
        name: "Create race",
        terminals: [
            MobileTerminalPreview(id: oldTerminalID, name: "Old", paneID: oldPaneID),
            MobileTerminalPreview(id: newTerminalID, name: "New", paneID: newPaneID, isFocused: true),
        ],
        panes: [
            MobilePanePreview(id: oldPaneID, spatialIndex: 0, terminalIDs: [oldTerminalID]),
            MobilePanePreview(id: newPaneID, spatialIndex: 1, isFocused: true, terminalIDs: [newTerminalID]),
        ],
        focusedPaneID: newPaneID,
        selectedTerminalID: newTerminalID
    )
    let current = try #require(store.workspaces.first)
    store.preserveNewerWorkspaceFocusIfNeeded(
        in: &authoritative,
        from: current,
        macID: nil,
        listStartedAtFocusRevision: listStartedAtFocusRevision
    )

    #expect(authoritative.focusedPaneID == newPaneID)
    #expect(authoritative.selectedTerminalID == newTerminalID)
}

@MainActor
@Test func mixedFocusEventPreservesOnlyItsAppliedDimension() throws {
    let oldPaneID = MobilePanePreview.ID(rawValue: "pane-old")
    let oldTerminalID = MobileTerminalPreview.ID(rawValue: "terminal-old")
    let newPaneID = MobilePanePreview.ID(rawValue: "pane-new")
    let newTerminalID = MobileTerminalPreview.ID(rawValue: "terminal-new")
    let existing = MobileWorkspacePreview(
        id: "workspace-mixed-race",
        name: "Mixed race",
        terminals: [
            MobileTerminalPreview(id: oldTerminalID, name: "Old", paneID: oldPaneID, isFocused: true),
        ],
        panes: [
            MobilePanePreview(id: oldPaneID, spatialIndex: 0, isFocused: true, terminalIDs: [oldTerminalID]),
        ],
        focusedPaneID: oldPaneID,
        selectedTerminalID: oldTerminalID
    )
    let store = MobileShellComposite(workspaces: [existing])
    let listStartedAtFocusRevision = store.workspaceFocusRevisionSnapshot()
    let event = try #require(MobileWorkspaceFocusEvent(payloadJSON: Data("""
    {"kind":"focus","workspace_id":"workspace-mixed-race","focused_pane_id":null,"selected_terminal_id":"terminal-new"}
    """.utf8)))

    store.applyWorkspaceFocusEvent(event, macID: nil)

    var authoritative = MobileWorkspacePreview(
        id: "workspace-mixed-race",
        name: "Mixed race",
        terminals: [
            MobileTerminalPreview(id: oldTerminalID, name: "Old", paneID: oldPaneID),
            MobileTerminalPreview(id: newTerminalID, name: "New", paneID: newPaneID, isFocused: true),
        ],
        panes: [
            MobilePanePreview(id: oldPaneID, spatialIndex: 0, terminalIDs: [oldTerminalID]),
            MobilePanePreview(id: newPaneID, spatialIndex: 1, isFocused: true, terminalIDs: [newTerminalID]),
        ],
        focusedPaneID: newPaneID,
        selectedTerminalID: newTerminalID
    )
    let current = try #require(store.workspaces.first)
    store.preserveNewerWorkspaceFocusIfNeeded(
        in: &authoritative,
        from: current,
        macID: nil,
        listStartedAtFocusRevision: listStartedAtFocusRevision
    )

    #expect(authoritative.focusedPaneID == nil)
    #expect(authoritative.panes.allSatisfy { !$0.isFocused })
    #expect(authoritative.selectedTerminalID == newTerminalID)
    #expect(authoritative.terminals.first(where: { $0.id == newTerminalID })?.isFocused == true)
}
