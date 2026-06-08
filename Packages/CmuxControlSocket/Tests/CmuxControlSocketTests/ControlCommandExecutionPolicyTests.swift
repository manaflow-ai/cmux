import Testing
@testable import CmuxControlSocket

@Suite("ControlCommandExecutionPolicy")
struct ControlCommandExecutionPolicyTests {
    @Test func vmPrefixedMethodsRunOnTheSocketWorker() {
        #expect(ControlCommandExecutionPolicy(forMethod: "vm.create") == .socketWorker(mainThreadCallable: false))
        #expect(ControlCommandExecutionPolicy(forMethod: "vm.anything.else").runsOnSocketWorker)
    }

    @Test func fixedWorkerSetRunsOnTheSocketWorker() {
        for method in [
            "system.ping", "system.capabilities", "auth.status", "feed.push",
            "browser.download.wait", "system.top", "system.memory",
            "workspace.remote.pty_bridge", "sidebar.custom.reload",
            "debug.sidebar.simulate_drag", "mobile.attach_ticket.create",
        ] {
            #expect(ControlCommandExecutionPolicy(forMethod: method).runsOnSocketWorker, "\(method)")
        }
    }

    @Test func everythingElseRunsOnTheMainActor() {
        for method in [
            "surface.list", "workspace.create", "window.list", "browser.eval",
            "mobile.terminal.create", "feed.jump", "vmx.create", "",
        ] {
            let policy = ControlCommandExecutionPolicy(forMethod: method)
            #expect(policy == .mainActor, "\(method)")
            #expect(!policy.runsOnSocketWorker, "\(method)")
        }
    }

    @Test func onlyPureProbesAreMainThreadCallable() {
        #expect(ControlCommandExecutionPolicy(forMethod: "system.ping") == .socketWorker(mainThreadCallable: true))
        #expect(ControlCommandExecutionPolicy(forMethod: "system.capabilities") == .socketWorker(mainThreadCallable: true))
        #expect(ControlCommandExecutionPolicy(forMethod: "system.top") == .socketWorker(mainThreadCallable: false))
        #expect(ControlCommandExecutionPolicy(forMethod: "vm.create") == .socketWorker(mainThreadCallable: false))
    }
}
