@testable import CmuxNextApp
@testable import CmuxNextActions
import CmuxNextServer
import Testing

/// An in-process Add Server… action approves only when the four fingerprint
/// words the server printed match the words the app derives from the server's
/// key, the same check a person makes in the approver sheet. Separate origin
/// tests prove that socket-originated CLI/MCP/script/page/remote runs cannot
/// reach this path.
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

/// Pairing a server grants a new install account authority. The code and words prove which
/// server key is waiting; they do not prove that the person authorized the enrollment.
struct ServerHeadlessApprovalOriginTests {
    @Test func onlyTheInProcessPersonMayApprove() {
        #expect(ServerHeadlessApproval.allows(origin: .user))
    }

    @Test(arguments: [ActionOrigin.cli, .mcp, .script, .remote, .page])
    func everyHeadlessCallerIsRefused(_ origin: ActionOrigin) {
        #expect(!ServerHeadlessApproval.allows(origin: origin))
    }

    @Test func addServerIsPersonOnlyAtTheSharedActionBoundary() throws {
        let descriptor = try #require(ServerActionCatalog.descriptors().first { $0.id == "server.addServer" })
        #expect(descriptor.isPersonOnly)
    }
}
