@testable import CmuxNextActions
import Testing

/// Issue manaflow-ai/cmux#25092: `cmux open-remote <host> [--split] [--cwd] [--cmd] [--name]
/// [--attach] [--ratio] [--label] [--focus=false]`, with Rex's `--ratio`, `--label` and `--focus`.
@MainActor @Suite struct OpenRemoteRequestTests {
    private func request(_ arguments: [String: ActionValue]) throws -> OpenRemoteRequest {
        try OpenRemoteRequest(ActionInvocation(arguments: arguments))
    }

    @Test func catalogHasTheVerbWithItsFlags() throws {
        let action = try #require(ActionCatalog.all.first { $0.id == "remote.openRemote" })
        #expect(action.cliName == "open-remote")
        let names = Set(action.arguments.map(\.name))
        #expect(names.isSuperset(of: ["host", "split", "cwd", "cmd", "name", "attach", "ratio", "focus"]))
        #expect(action.arguments.first { $0.name == "host" }?.isRequired == true)
        #expect(action.arguments.filter { $0.name != "host" }.allSatisfy { !$0.isRequired })
    }

    @Test func hostOnlyOpensATab() throws {
        let value = try request(["host": .string("cmux-orchestrator-1")])
        #expect(value.host == "cmux-orchestrator-1")
        #expect(value.placement == .tab)
        #expect(value.focus)
        #expect(value.ratio == nil && value.cwd == nil && value.cmd == nil && value.name == nil && value.attach == nil)
    }

    @Test(arguments: [("bottom", OpenRemotePlacement.down), ("below", .down), ("down", .down), ("right", .right), ("tab", .tab)])
    func splitWords(word: String, placement: OpenRemotePlacement) throws {
        #expect(try request(["host": .string("h"), "split": .string(word)]).placement == placement)
    }

    @Test(arguments: ["left", "top", "window", "diagonal"])
    func unsupportedSplitIsRefused(word: String) {
        #expect(throws: OpenRemoteRequest.Failure.self) { try request(["host": .string("h"), "split": .string(word)]) }
    }

    @Test func missingHostIsRefused() {
        #expect(throws: OpenRemoteRequest.Failure.missingHost) { try request([:]) }
        #expect(throws: OpenRemoteRequest.Failure.missingHost) { try request(["host": .string("  ")]) }
    }

    @Test func labelIsRexsNameAndNameWins() throws {
        #expect(try request(["host": .string("h"), "label": .string("logs")]).name == "logs")
        #expect(try request(["host": .string("h"), "label": .string("a"), "name": .string("b")]).name == "b")
    }

    @Test func ratioMustBeBetweenZeroAndOne() throws {
        #expect(try request(["host": .string("h"), "ratio": .string("0.3")]).ratio == 0.3)
        #expect(throws: OpenRemoteRequest.Failure.self) { try request(["host": .string("h"), "ratio": .string("1.5")]) }
        #expect(throws: OpenRemoteRequest.Failure.self) { try request(["host": .string("h"), "ratio": .string("wide")]) }
    }

    @Test func focusFalseKeepsFocus() throws {
        #expect(try request(["host": .string("h"), "focus": .bool(false)]).focus == false)
        #expect(try request(["host": .string("h"), "focus": .string("false")]).focus == false)
    }

    @Test func idempotencyKeyIsHostPlusNameOrAttach() throws {
        let plain = try request(["host": .string("H")])
        #expect(plain.key == "h")
        #expect(try request(["host": .string("H"), "name": .string("Logs")]).key == "h/logs")
        #expect(try request(["host": .string("H"), "attach": .string("claude")]).key == "h/claude")
        #expect(try request(["host": .string("H"), "name": .string("x"), "attach": .string("claude")]).key == "h/claude")
    }

    @Test func hostMatchingPrefersIdThenNameThenDestination() {
        let machines = [
            OpenRemoteMachine(id: "m-1", name: "cmux-orchestrator-1", destination: "lawrence@100.64.0.9"),
            OpenRemoteMachine(id: "m-2", name: "mini", destination: "mini.tail.ts.net"),
        ]
        #expect(OpenRemoteMachine.match("m-2", in: machines)?.id == "m-2")
        #expect(OpenRemoteMachine.match("CMUX-Orchestrator-1", in: machines)?.id == "m-1")
        #expect(OpenRemoteMachine.match("lawrence@100.64.0.9", in: machines)?.id == "m-1")
        #expect(OpenRemoteMachine.match("mini.tail.ts.net", in: machines)?.id == "m-2")
        #expect(OpenRemoteMachine.match("100.64.0.9", in: machines)?.id == "m-1")
        #expect(OpenRemoteMachine.match("nope", in: machines) == nil)
    }
}

@MainActor @Suite struct OpenRemoteIdempotencyTests {
    @Test func aSecondRunFindsTheTabTheFirstMade() throws {
        let plain = try OpenRemoteRequest(ActionInvocation(arguments: ["host": .string("h")]))
        #expect(plain.matchesTab(name: nil, title: "Terminal on h", defaultTitle: "Terminal on h"))
        #expect(!plain.matchesTab(name: "logs", title: "Terminal on h", defaultTitle: "Terminal on h"))
        let named = try OpenRemoteRequest(ActionInvocation(arguments: ["host": .string("h"), "name": .string("Logs")]))
        #expect(named.matchesTab(name: "logs", title: "x", defaultTitle: "Terminal on h"))
        #expect(!named.matchesTab(name: nil, title: "Terminal on h", defaultTitle: "Terminal on h"))
    }
}
