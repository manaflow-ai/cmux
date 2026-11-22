import AppKit
import CmuxNextActions
import CmuxNextSettings
import CmuxNextSidebar
import CmuxNextSidebarActions
import Testing

@MainActor @Suite(.timeLimit(.minutes(1)))
struct SidebarRemoteSessionTests {
    @Test func newSessionUsesTheClickedMachineAfterAnotherMenuIsOpened() async throws {
        let experiment = SidebarRemoteHostExperiment()
        let registry = ActionRegistry(catalog: [])
        let sidebar = NSView()
        var starts: [MachineID] = []
        var settings = CmuxConfigSnapshot.empty
        func menu(_ machine: MachineID) throws -> NSMenu {
            try #require(experiment.menu(NSMenu(), for: .section(.machine(machine)), anchoredIn: sidebar,
                                         settings: settings, registry: registry) { id in
                starts.append(id)
                return nil
            })
        }

        let first = MachineID("ssh:first"), second = MachineID("ssh:second")
        #expect(try menu(first).items.isEmpty)
        settings.root = .object(["labs": .object(["sidebarRemoteHosts": .bool(true)])])
        #expect(try menu(.local).items.isEmpty)
        let firstMenu = try menu(first)
        let secondMenu = try menu(second)
        #expect(firstMenu.items.count == 1)
        #expect(secondMenu.items.count == 1)
        let item = try #require(firstMenu.items.first)
        let target = try #require(item.target as? NSObject)
        let selection = try #require(item.action)
        let work = registry.capturingWork { _ = target.perform(selection, with: item) }
        let create = try #require(work.first)
        let failure = await create.value
        #expect(failure == nil)
        #expect(starts == [first])
    }
}
