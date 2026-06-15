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
            "system.ping", "system.capabilities", "auth.status", "auth.sign_in_url",
            "feed.push", "browser.download.wait", "system.top", "system.memory",
            "workspace.remote.pty_bridge", "workspace.env", "sidebar.custom.reload",
            "debug.sidebar.simulate_drag", "mobile.attach_ticket.create",
            // JavaScript-evaluating browser methods block on page JS and must
            // not hold the main actor (see socketWorkerMethods rationale).
            "browser.eval", "browser.wait", "browser.snapshot", "browser.click",
            "browser.fill", "browser.navigate", "browser.get.text",
            "browser.find.text", "browser.highlight",
        ] {
            #expect(ControlCommandExecutionPolicy(forMethod: method).runsOnSocketWorker, "\(method)")
        }
    }

    @Test func everythingElseRunsOnTheMainActor() {
        for method in [
            "surface.list", "workspace.create", "window.list", "browser.url.get",
            "browser.open_split", "browser.screenshot", "browser.cookies.get",
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
