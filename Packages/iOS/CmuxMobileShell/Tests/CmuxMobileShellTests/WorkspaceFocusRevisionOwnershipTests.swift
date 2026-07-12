import CmuxMobileShellModel
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

    store.currentTeamDidChange()

    #expect(store.workspaceFocusEventRevisionsByMac[foregroundMacID] == ["foreground-workspace": 3])
    #expect(store.workspaceFocusEventRevisionsByMac[secondaryMacID] == nil)
}

@MainActor
@Test func secondaryDisappearanceEvictsItsFocusRevisionOwner() async throws {
    let router = RoutingHostRouter()
    let pairedMacStore = DelayedTeamPairedMacStore(recordsByTeam: ["team-a": []], blockedTeams: [])
    let store = makeRoutingMultiMacStore(router: router, pairedMacStore: pairedMacStore)
    let secondaryMacID = "vanished-secondary"
    try installSecondaryClient(on: store, macDeviceID: secondaryMacID, router: router)
    store.workspaceFocusEventRevisionsByMac[secondaryMacID] = ["workspace-old": 7]

    await store.refreshSecondaryMacWorkspaces()

    #expect(store.secondaryMacSubscriptions[secondaryMacID] == nil)
    #expect(store.workspaceFocusEventRevisionsByMac[secondaryMacID] == nil)
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
