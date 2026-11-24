import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextRemoteLocalhostService
import CmuxNextTestSupport
import Foundation
import Testing
@testable import CmuxNextApp

/// A Cloud chat's sign-in tab is bound to the chat's machine (ChatMachineSignInTab): its localhost
/// is that machine's, never this Mac's. The binding outlives a relaunch (a restored tab still holds
/// the machine's route), and only closed tabs' bindings are ever dropped.
@MainActor
struct ChatMachineSignInBindingTests {
    static func defaults() -> UserDefaults {
        let name = "cmux-next-sign-in-binding-\(UUID().uuidString)"
        let defaults = UserDefaults(testSuiteName: name)!
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

    @Test func settingsApprovalOnlyForwardsItsCallbackWhileCurrent() throws {
        let defaults = Self.defaults()
        let machines = MachineRegistry(local: DaemonService())
        let machine = CloudTestLink.session(id: "vm-1", name: "Approval")
        machines.add(machine)
        machine.daemon.store.noteHandshake(DaemonIdentity(capabilities: [DaemonCapability.loopbackForward.rawValue],
                                                         generation: "callback-test"))
        let service = RemoteLocalhostService(machines: machines, environment: [:], defaults: defaults)
        let page = NSObject()
        let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 7), kind: .browser))
        let callback = try #require(URL(string: "http://localhost:8100/callback?code=test"))
        let wrongPort = try #require(URL(string: "http://localhost:8101/callback"))
        let wrongPath = try #require(URL(string: "http://localhost:8100/other"))
        var current = true
        service.expectCallbackPage(page, machine: "vm-1", port: 8100, owner: "approval", current: { current })
        service.adoptPage(page, key: tab.id)
        #expect(service.storePlan(for: tab, url: callback) == .derived)
        #expect(service.storePlan(for: tab, url: wrongPort) == .blank)
        #expect(service.storePlan(for: tab, url: wrongPath) == .blank)

        current = false
        #expect(service.storePlan(for: tab, url: callback) == .blank)
        current = true
        #expect(service.endSignInApproval(owner: "other").isEmpty)
        #expect(service.endSignInApproval(owner: "approval") == [tab.id])
        #expect(service.isSignInApprovalTab(tab.id))
        #expect(service.storePlan(for: tab, url: callback) == .blank)
        let relaunched = RemoteLocalhostService(machines: machines, environment: [:], defaults: defaults)
        #expect(relaunched.boundMachine(ofTab: tab.id) == "vm-1")
        #expect(relaunched.storePlan(for: tab, url: callback) == .blank)
    }

    @Test func theCallbackContextIsPrivateAndExpiredReplacementsClose() async throws {
        let machines = MachineRegistry(local: DaemonService())
        let service = RemoteLocalhostService(machines: machines, environment: [:], defaults: Self.defaults())
        let offTheRecord = OffTheRecordProfiles()
        let routing = SignInBrowserRouting(localhost: service, offTheRecord: offTheRecord)
        let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 7), kind: .browser))
        let callback = try #require(URL(string: "http://localhost:8100/callback?code=test"))
        let page = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration())
        service.expectCallbackPage(page, machine: "vm-1", port: 8100, owner: "approval", current: { true })
        routing.adopt(page, for: tab.id)
        var base = BrowserTabConfiguration(initialURL: callback)
        base.restoreState = .chromium("fixture")
        let machineStore = BrowserMachineStore(machineKey: "fixture", machineName: "Approval", proxyPort: 8080)
        let configure: SignInBrowserRouting.Configure = { _, _, base in
            var routed = base
            routed.machineStore = machineStore
            routed.navigationGuard = .loopbackOnly
            return routed
        }

        let routed = await routing.configuration(for: tab, base: base, configure: configure)
        #expect(routed.initialURL == callback)
        #expect(routed.machineStore == machineStore)
        #expect(offTheRecord.isOffTheRecord(routed.profile))
        #expect(routed.restoreState == nil)

        let replacement = MockBrowserEngine(kind: .cef).makeMockTab(routed)
        var installed = false
        await routing.replace(for: tab.id, url: callback, tabExists: { true }) {
            #expect(service.endSignInApproval(owner: "approval") == [tab.id])
            return replacement
        } install: { _ in
            installed = true
        }
        #expect(!installed)
        #expect(replacement.isClosed)

        let expired = await routing.configuration(for: tab, base: base, configure: configure)
        #expect(expired.initialURL == nil)
        #expect(expired.machineStore == nil)
        #expect(expired.restoreState == nil)
        #expect(expired.navigationGuard == .noLoopback)
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
