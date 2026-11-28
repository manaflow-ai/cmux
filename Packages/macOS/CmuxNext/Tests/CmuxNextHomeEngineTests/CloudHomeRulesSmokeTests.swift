import CmuxHomeCore
import CmuxNextDaemon
@testable import CmuxNextHomeEngine
import CmuxNextHomeModel
import Foundation
import Testing

/// The cloud area's Swift callers of the Rust rules (`cloud.archive_*`, `cloud.requests_*`,
/// `cloud.source_message_request`) over the FFI. The rules' cases themselves are the Rust tests
/// (cmux-home-rules `tests/cloud_home.rs`).
@MainActor
@Suite struct CloudHomeRulesSmokeTests {
    @Test func theDefaultChiefStaysHiddenHereOnly() async {
        let defaults = UserDefaults(suiteName: "CloudHomeRulesSmokeTests.\(UUID().uuidString)")!
        let archive = HomeChiefArchive(store: .init(defaults: defaults))
        let chief = HomeChiefRecord(id: "agent_default", name: "Chief", isDefault: true, rev: 1, mainConversation: nil)
        var calls = 0
        let account = HomeChiefArchive.Account(chiefs: { [chief] }, gone: { [] }, listed: { true },
                                               archive: { _ in calls += 1; return .archived },
                                               reread: { true }, archived: { _ in })
        #expect(await archive.archive(chief.id, in: account) == .hiddenHere)
        #expect(archive.hidden == [chief.id])
        #expect(calls == 0)
    }

    @Test func aRefusedAnswerPutsTheRequestBack() async {
        let request = HomeMessageRequest(conversation: ConversationID("conv_a"), inviter: "Frank", isGroup: false, title: nil,
                                         preview: "hi", createdAt: Date(timeIntervalSince1970: 1_700_000_000.25), trusted: true)
        let requests = HomeMessageRequests(source: RefusingSource(listed: [request]))
        await requests.reload()
        #expect(requests.items == [request])
        #expect(await requests.answer(request.conversation, .accept) == false)
        #expect(requests.items == [request])
    }

    @Test func aListedRowDropsAnInternalIDTitle() throws {
        let json = #"{"conversation":"conv_a","inviter":"Frank","kind":"group","title":"conv_0Y05MEWEFMQQB63VDHQB9MXAJT","trusted":true}"#
        let row = try JSONDecoder().decode(CloudMessageRequest.self, from: Data(json.utf8))
        let request = try #require(CloudHomeSource.request(row))
        #expect(request.conversation == ConversationID("conv_a"))
        #expect(request.isGroup && request.trusted)
        #expect(request.title == nil)
    }
}

private final class RefusingSource: HomeMessageRequestSource {
    let listed: [HomeMessageRequest]
    init(listed: [HomeMessageRequest]) { self.listed = listed }
    func messageRequests() async throws -> [HomeMessageRequest] { listed }
    func answer(_ conversation: ConversationID, _ answer: HomeRequestAnswer) async throws { throw CancellationError() }
}
