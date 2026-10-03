@testable import CmuxNextApp
import CmuxNextSidebar
import Testing

/// Placeholder rows fill a connecting machine only while the app launches;
/// a later Cloud reconnect shows its section empty, not a skeleton.
@MainActor @Suite struct SidebarSeedTests {
    static func connecting() -> [SidebarSection] {
        [SidebarSection(kind: .machine(SidebarMachine(id: MachineID("cloud-1"), name: "Cloud", kind: .cloud, status: .connecting)),
                        nodes: [])]
    }

    @Test func aConnectingMachineShowsPlaceholdersOnlyAtLaunch() {
        var seed = SidebarSeed()
        let atLaunch = seed.merge(Self.connecting(), launching: true).flatMap(\.workspaces)
        #expect(atLaunch.count == SidebarSeed.placeholderCount)
        #expect(atLaunch.allSatisfy { $0.rowState == .placeholder })
        var later = SidebarSeed()
        #expect(later.merge(Self.connecting(), launching: false).flatMap(\.workspaces).isEmpty)
    }
}
