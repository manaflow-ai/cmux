import CmuxNextDaemonService
import CmuxNextRemoteLocalhostService
import Foundation
import Testing
@testable import CmuxNextApp

/// A Cloud chat's sign-in tab is bound to the chat's machine (ChatMachineSignInTab): its localhost
/// is that machine's, never this Mac's. The binding outlives a relaunch (a restored tab still holds
/// the callback address), and only closed tabs' bindings are ever dropped.
@MainActor
struct ChatMachineSignInBindingTests {
    static func defaults() -> UserDefaults {
        let name = "cmux-next-sign-in-binding-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func aBindingOutlivesARelaunch() {
        let defaults = Self.defaults()
        let machines = MachineRegistry(local: DaemonService())
        let first = RemoteLocalhostService(machines: machines, environment: [:], defaults: defaults)
        let page = NSObject()
        first.adoptPage(page, key: "tab-unexpected")
        #expect(first.boundMachine(ofTab: "tab-unexpected") == nil, "only a page made for the machine binds its tab")
        first.expectPage(page, machine: "vm-1")
        first.adoptPage(page, key: "tab-1")
        #expect(first.boundMachine(ofTab: "tab-1") == "vm-1")

        let relaunched = RemoteLocalhostService(machines: machines, environment: [:], defaults: defaults)
        #expect(relaunched.boundMachine(ofTab: "tab-1") == "vm-1", "the restored tab is still bound")
    }

    @Test func pastTheLimitOnlyClosedTabsLoseTheirBinding() {
        let defaults = Self.defaults()
        let service = RemoteLocalhostService(machines: MachineRegistry(local: DaemonService()), environment: [:], defaults: defaults)
        for index in 0...256 {
            let page = NSObject()
            service.expectPage(page, machine: "vm-1")
            service.adoptPage(page, key: "tab-\(index)")
        }
        // No tab is on any machine here: the oldest closed one goes, the newest stays.
        #expect(service.boundMachine(ofTab: "tab-0") == nil)
        #expect(service.boundMachine(ofTab: "tab-256") == "vm-1")
    }
}
