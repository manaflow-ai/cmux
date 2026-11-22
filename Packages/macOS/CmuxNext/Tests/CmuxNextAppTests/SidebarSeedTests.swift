@testable import CmuxNextApp
import CmuxNextSidebar
import Testing

/// Placeholder rows fill a connecting machine only while the app launches;
/// a later Cloud reconnect shows its section empty, not a skeleton. A
/// section that showed placeholders at launch keeps them until its machine
/// connects or fails, so the end of the launch never empties it in between.
@MainActor @Suite struct SidebarSeedTests {
    static let cloud = MachineID("cloud-1")

    static func section(_ status: SidebarMachine.Status, rows: [String] = []) -> [SidebarSection] {
        [SidebarSection(kind: .machine(SidebarMachine(id: cloud, name: "Cloud", kind: .cloud, status: status)),
                        nodes: rows.map { .workspace(SidebarWorkspace(id: WorkspaceID($0), machineID: cloud, title: $0)) })]
    }

    static func connecting() -> [SidebarSection] { section(.connecting) }

    static func rowStates(_ sections: [SidebarSection]) -> [SidebarRowState] {
        sections.flatMap(\.workspaces).map(\.rowState)
    }

    static let placeholders = Array(repeating: SidebarRowState.placeholder, count: SidebarSeed.placeholderCount)

    @Test func aConnectingMachineShowsPlaceholdersOnlyAtLaunch() {
        var seed = SidebarSeed()
        let atLaunch = seed.merge(Self.connecting(), launching: true).flatMap(\.workspaces)
        #expect(atLaunch.count == SidebarSeed.placeholderCount)
        #expect(atLaunch.allSatisfy { $0.rowState == .placeholder })
        var later = SidebarSeed()
        #expect(later.merge(Self.connecting(), launching: false).flatMap(\.workspaces).isEmpty)
    }

    /// Launch ends while Cloud still connects: placeholders, then rows,
    /// never an empty section between them.
    @Test func placeholdersOutlastTheLaunchUntilTheMachineConnects() {
        var seed = SidebarSeed()
        #expect(Self.rowStates(seed.merge(Self.connecting(), launching: true)) == Self.placeholders)
        #expect(Self.rowStates(seed.merge(Self.connecting(), launching: false)) == Self.placeholders,
                "the section emptied when the launch ended")
        #expect(Self.rowStates(seed.merge(Self.section(.connected, rows: ["a", "b"]), launching: false)) == [.live, .live])
    }

    /// A machine that fails (offline, or its first connection gave up)
    /// drops its placeholders: no skeleton under a machine that is not coming.
    @Test func placeholdersEndWhenTheMachineFails() {
        var offline = SidebarSeed()
        _ = offline.merge(Self.connecting(), launching: true)
        #expect(offline.merge(Self.section(.offline), launching: false).flatMap(\.workspaces).isEmpty)
        var unavailable = SidebarSeed()
        _ = unavailable.merge(Self.connecting(), launching: true)
        _ = unavailable.merge(Self.connecting(), launching: false)
        #expect(unavailable.merge(Self.connecting(), launching: false, failed: [Self.cloud]).flatMap(\.workspaces).isEmpty)
    }

    /// Once the machine connected, a later reconnect after launch shows the
    /// section empty, never placeholders again.
    @Test func aReconnectAfterLaunchNeverShowsPlaceholders() {
        var seed = SidebarSeed()
        _ = seed.merge(Self.connecting(), launching: true)
        _ = seed.merge(Self.connecting(), launching: false)
        _ = seed.merge(Self.section(.connected, rows: ["a"]), launching: false)
        #expect(seed.merge(Self.connecting(), launching: false).flatMap(\.workspaces).isEmpty)
    }
}
