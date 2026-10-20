@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextServer
import Testing

/// Add Server… without a window (`cmux servers add --code CODE --words "…"`, the
/// `app_servers_add` MCP tool) approves only when the four fingerprint words the
/// server printed match the words the app derives from the server's key, the
/// same check a person makes in the approver sheet.
@MainActor
struct ServerHeadlessApprovalTests {
    private let code = MockServerScenario.offerCode
    private let words = MockServerScenario.offerWords

    private func approvals(_ source: MockServerSource) -> [ServerIntentKind] {
        source.received.map(\.kind).filter {
            if case .approveCode = $0 { return true }
            return false
        }
    }

    @Test func approvesWhenCodeAndWordsMatch() async {
        let source = MockServerSource()
        let reject = await ServerHeadlessApproval.run(source: source, code: code, words: words.joined(separator: " "),
                                                      name: nil, runChief: false)
        #expect(reject == nil)
        #expect(approvals(source) == [.approveCode(code: code, team: "team_personal", name: "build-01", placeChief: false)])
    }

    @Test(arguments: ["COPPER lantern Meadow violet", "copper, lantern, meadow, violet", "copper-lantern-meadow-violet", "  copper\tlantern  meadow violet "])
    func wordsMatchIgnoringCaseAndSeparators(_ typed: String) async {
        let source = MockServerSource()
        let reject = await ServerHeadlessApproval.run(source: source, code: code, words: typed, name: nil, runChief: false)
        #expect(reject == nil)
        #expect(approvals(source).count == 1)
    }

    @Test(arguments: [nil, "", "   "] as [String?])
    func refusesWithoutWords(_ typed: String?) async {
        let source = MockServerSource()
        let reject = await ServerHeadlessApproval.run(source: source, code: code, words: typed, name: nil, runChief: false)
        #expect(reject != nil)
        #expect(approvals(source).isEmpty)
    }

    @Test(arguments: ["copper lantern meadow orange", "lantern copper meadow violet", "copper lantern meadow", "copper lantern meadow violet extra"])
    func refusesWhenWordsDiffer(_ typed: String) async {
        let source = MockServerSource()
        let reject = await ServerHeadlessApproval.run(source: source, code: code, words: typed, name: nil, runChief: false)
        let text = try? #require(reject)
        #expect(approvals(source).isEmpty)
        // The refusal never echoes the expected words back (they are the swap check).
        for word in words { #expect(text?.localizedCaseInsensitiveContains(word) == false) }
    }

    @Test func unknownCodeIsRefusedBeforeWordsAreChecked() async {
        let source = MockServerSource()
        let reject = await ServerHeadlessApproval.run(source: source, code: "ZZZZ9999", words: words.joined(separator: " "),
                                                      name: nil, runChief: false)
        #expect(reject != nil)
        #expect(approvals(source).isEmpty)
    }
}

/// Only callers on this Mac may approve without the sheet: the user, the local CLI, a local
/// MCP agent or script. Another client (a phone, another Mac) or a web page never may.
struct ServerHeadlessApprovalOriginTests {
    @Test(arguments: [ActionOrigin.user, .cli, .mcp, .script])
    func localCallersMayApprove(_ origin: ActionOrigin) {
        #expect(ServerHeadlessApproval.allows(origin: origin))
    }

    @Test(arguments: [ActionOrigin.remote, .page])
    func remoteCallersAndPagesMayNot(_ origin: ActionOrigin) {
        #expect(!ServerHeadlessApproval.allows(origin: origin))
    }
}
