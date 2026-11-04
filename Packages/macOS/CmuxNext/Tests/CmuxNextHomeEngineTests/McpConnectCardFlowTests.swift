import CmuxNextHome
import Testing

/// The MCP connect card's state machine (plans/cmux-next/mcp-connect-DESIGN.md sections 3 and 4):
/// only the person's steps approve, the scope is theirs, and a key never prints.
@MainActor @Suite struct McpConnectCardFlowTests {
    private func card(_ auth: McpConnectCard.Auth, scope: McpConnectCard.Scope = .chief) -> McpConnectCard {
        McpConnectCard(requestID: "r1", agent: "Chief", reason: "file issues", title: "Linear", publisher: "linear.app",
                       verified: true, transport: .remote(url: "https://mcp.linear.app/mcp"), auth: auth, proposedScope: scope)
    }

    @Test func oauthConnectApprovesWithChosenScopeThenSignsIn() {
        var flow = McpConnectCardFlow(card: card(.oauth(scopes: ["read", "write"])))
        #expect(flow.scope == .chief)
        flow.choose(.chat)
        #expect(flow.connect() == [.approve(scope: .chat), .beginSignIn])
        #expect(flow.phase == .signingIn)
        flow.signedIn()
        #expect(flow.phase == .connecting)
        flow.connected([McpConnectCard.Tool(name: "list_issues", kind: .read)])
        #expect(flow.phase == .connected(tools: [McpConnectCard.Tool(name: "list_issues", kind: .read)]))
    }

    @Test func scopeCannotChangeAfterApproval() {
        var flow = McpConnectCardFlow(card: card(.oauth(scopes: [])))
        _ = flow.connect()
        flow.choose(.everywhere)
        #expect(flow.scope == .chief)
    }

    @Test func connectTwiceSendsOneApproval() {
        var flow = McpConnectCardFlow(card: card(.none))
        #expect(flow.connect() == [.approve(scope: .chief)])
        #expect(flow.connect().isEmpty)
        #expect(flow.phase == .connecting)
    }

    @Test func keyServerAsksForKeyAndSendsItOnce() {
        var flow = McpConnectCardFlow(card: card(.key(name: "CONTEXT7_API_KEY", optional: false)))
        #expect(flow.connect() == [.approve(scope: .chief)])
        #expect(flow.phase == .enterKey)
        #expect(flow.submit(McpConnectKey("  ")).isEmpty)
        #expect(flow.phase == .enterKey)
        let key = McpConnectKey("ctx7sk-secret")
        #expect(flow.submit(key) == [.submitKey(key)])
        #expect(flow.phase == .connecting)
        #expect(flow.submit(key).isEmpty)
    }

    @Test func optionalKeyConnectsWithoutAKey() {
        var flow = McpConnectCardFlow(card: card(.key(name: "K", optional: true)))
        _ = flow.connect()
        #expect(flow.submit(McpConnectKey("")).isEmpty)
        #expect(flow.phase == .connecting)
    }

    @Test func cancelDeclinesAtAnyStepBeforeConnected() {
        for steps in 0...2 {
            var flow = McpConnectCardFlow(card: card(.oauth(scopes: [])))
            if steps >= 1 { _ = flow.connect() }
            if steps >= 2 { flow.signedIn() }
            #expect(flow.cancel() == [.decline])
            #expect(flow.phase == .declined)
            flow.connected([])
            #expect(flow.phase == .declined, "a late daemon answer does not revive a declined card")
        }
        var done = McpConnectCardFlow(card: card(.none))
        _ = done.connect()
        done.connected([])
        #expect(done.cancel().isEmpty)
    }

    @Test func daemonAnswersCannotSkipThePerson() {
        var flow = McpConnectCardFlow(card: card(.oauth(scopes: [])))
        flow.signedIn()
        flow.connected([McpConnectCard.Tool(name: "x", kind: .write)])
        #expect(flow.phase == .ask, "nothing connects before the person pressed Connect")
    }

    @Test func failureShowsAndEndsTheCard() {
        var flow = McpConnectCardFlow(card: card(.oauth(scopes: [])))
        _ = flow.connect()
        flow.failed("refused")
        #expect(flow.phase == .failed("refused"))
        #expect(flow.cancel().isEmpty)
    }

    @Test func keyNeverPrints() {
        let key = McpConnectKey("ctx7sk-very-secret")
        #expect(!String(describing: key).contains("secret"))
        #expect(!String(reflecting: key).contains("secret"))
        var dumped = ""
        dump(key, to: &dumped)
        #expect(!dumped.contains("secret"))
        #expect(!"\(McpConnectCardFlow.Effect.submitKey(key))".contains("secret"))
        #expect(key.reveal() == "ctx7sk-very-secret")
    }

    @Test func riskyMeansUnverifiedIdnOrLocal() {
        #expect(!card(.none).risky)
        var c = card(.none)
        c.verified = false
        #expect(c.risky)
        c = card(.none)
        c.idn = true
        #expect(c.risky)
        c = card(.none)
        c.transport = .local(argv: ["x"], binarySHA256: "00", fetchesCode: false)
        #expect(c.risky)
    }
}
