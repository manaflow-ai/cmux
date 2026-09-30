import Testing
@testable import CmuxFoundation

@Suite("cmux CLI session scope")
struct CmuxCLISessionScopeTests {
    @Test("object commands take --session and --machine after the command")
    func objectCommandsTakeTheScope() {
        let send = CmuxCLISessionScope.extract(command: "send", arguments: ["--surface", "surface:2", "--session", "build-box", "ls"])
        #expect(send.session == "build-box")
        #expect(send.remaining == ["--surface", "surface:2", "ls"])
        let tree = CmuxCLISessionScope.extract(command: "tree", arguments: ["--machine=devvm"])
        #expect(tree.session == "devvm" && tree.remaining.isEmpty)
    }

    @Test("other commands keep their own --session option")
    func otherCommandsKeepTheirOption() {
        let hooks = CmuxCLISessionScope.extract(command: "hooks", arguments: ["codex", "--session", "abc"])
        #expect(hooks.session == nil)
        #expect(hooks.remaining == ["codex", "--session", "abc"])
        let vm = CmuxCLISessionScope.extract(command: "vm", arguments: ["tui", "--machine", "m1"])
        #expect(vm.session == nil && vm.remaining == ["tui", "--machine", "m1"])
    }

    @Test("a terminator ends scope parsing")
    func terminatorEndsParsing() {
        let send = CmuxCLISessionScope.extract(command: "send", arguments: ["--", "--session", "x"])
        #expect(send.session == nil && send.remaining == ["--", "--session", "x"])
    }

    @Test("only object methods get the session param")
    func methodsThatHonorTheScope() {
        #expect(CmuxCLISessionScope.applies(toMethod: "surface.send_text"))
        #expect(CmuxCLISessionScope.applies(toMethod: "workspace.list"))
        #expect(CmuxCLISessionScope.applies(toMethod: "system.tree"))
        #expect(!CmuxCLISessionScope.applies(toMethod: "system.ping"))
        #expect(!CmuxCLISessionScope.applies(toMethod: "vm.list"))
    }

    @Test("action targets are qualified with the scope")
    func actionTargetsAreQualified() {
        #expect(CmuxCLISessionScope.qualify(target: "surface:3", session: "bb") == "bb:surface:3")
        #expect(CmuxCLISessionScope.qualify(target: "tab:3", session: "bb") == "bb:tab:3")
        #expect(CmuxCLISessionScope.qualify(target: "other:surface:3", session: "bb") == "other:surface:3")
        #expect(CmuxCLISessionScope.qualify(target: "tab-1", session: "bb") == "tab-1")
    }

    @Test("handle refs may carry a session qualifier, windows never")
    func handleRefs() {
        #expect(CmuxCLISessionScope.isHandleRef("workspace:2"))
        #expect(CmuxCLISessionScope.isHandleRef("build-box:surface:12"))
        #expect(!CmuxCLISessionScope.isHandleRef("build-box:window:1"))
        #expect(!CmuxCLISessionScope.isHandleRef(":workspace:1"))
        #expect(!CmuxCLISessionScope.isHandleRef("workspace:x"))
    }
}

@Suite("cmux CLI scoped ref matching")
struct CmuxCLIScopedRefMatchTests {
    @Test("an unqualified ref names the scoped session's listed ref")
    func scopedMatch() {
        #expect(CmuxCLISessionScope.ref("build-box:workspace:2", matches: "workspace:2", scoped: true))
        #expect(!CmuxCLISessionScope.ref("build-box:workspace:2", matches: "workspace:2", scoped: false))
        #expect(CmuxCLISessionScope.ref("workspace:2", matches: "workspace:2", scoped: false))
        #expect(!CmuxCLISessionScope.ref("build-box:workspace:12", matches: "workspace:2", scoped: true))
    }
}
