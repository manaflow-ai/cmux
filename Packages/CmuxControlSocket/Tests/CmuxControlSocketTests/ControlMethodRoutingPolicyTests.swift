import Testing
@testable import CmuxControlSocket

@Suite("ControlMethodRoutingPolicy")
struct ControlMethodRoutingPolicyTests {
    private let policy = ControlMethodRoutingPolicy()

    @Test func vmPrefixedMethodsRunOnTheSocketWorker() {
        #expect(policy.executionPolicy(forMethod: "vm.create") == .socketWorker)
        #expect(policy.executionPolicy(forMethod: "vm.anything.else") == .socketWorker)
    }

    @Test func fixedWorkerSetRunsOnTheSocketWorker() {
        for method in [
            "system.ping", "system.capabilities", "auth.status", "feed.push",
            "browser.download.wait", "system.top", "system.memory",
            "workspace.remote.pty_bridge", "sidebar.custom.reload",
            "debug.sidebar.simulate_drag", "mobile.attach_ticket.create",
        ] {
            #expect(policy.executionPolicy(forMethod: method) == .socketWorker, "\(method)")
        }
    }

    @Test func everythingElseRunsOnTheMainActor() {
        for method in [
            "surface.list", "workspace.create", "window.list", "browser.eval",
            "mobile.terminal.create", "feed.jump", "vmx.create", "",
        ] {
            #expect(policy.executionPolicy(forMethod: method) == .mainActor, "\(method)")
        }
    }

    @Test func onlyPureProbesAreMainThreadCallable() {
        #expect(policy.isMainThreadCallable(method: "system.ping"))
        #expect(policy.isMainThreadCallable(method: "system.capabilities"))
        #expect(!policy.isMainThreadCallable(method: "system.top"))
        #expect(!policy.isMainThreadCallable(method: "vm.create"))
        #expect(!policy.isMainThreadCallable(method: "surface.list"))
    }
}
