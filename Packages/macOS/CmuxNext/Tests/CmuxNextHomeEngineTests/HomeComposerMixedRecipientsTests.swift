import CmuxHomeCore
import CmuxNextDaemon
import CmuxNextHome
@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// New Message with people and email addresses in one To: field (Austin Wang,
/// Aziz Albahar, leo@cmux.com) starts the group in one step: the people join
/// it and each address gets an invite into it, instead of the sheet refusing
/// with "A group can include people or email addresses, not both."
@MainActor
@Suite struct HomeComposerMixedRecipientsTests {
    private static let austin = HomeContact(id: ParticipantID("austin"), name: "Austin Wang", source: .team)
    private static let aziz = HomeContact(id: ParticipantID("aziz"), name: "Aziz Albahar", source: .team)
    private static let leo = ContactAddress.parse("leo@cmux.com")!

    @Test func peopleAndAnAddressStartOneGroup() async throws {
        var ops: [HomeOp] = []
        let created = ConversationID("conv_mixed")
        let composer = HomeComposer(perform: { op in
            ops.append(op)
            return HomeOpResult(rev: 1, conversation: created)
        }, describe: { String(describing: $0) })
        let outcome = await composer.start([.contact(Self.austin), .address(Self.leo), .contact(Self.aziz)], title: "")
        #expect(outcome == .opened(created))
        #expect(outcome.message == nil)
        #expect(ops == [.createGroup(title: "", participants: [Self.austin.id, Self.aziz.id], invites: [Self.leo])])
    }

    /// The router sends a group with invites to the cloud, even when its people are local.
    @Test func aGroupWithInvitesCreatesItThenInvitesEachAddressIntoIt() async throws {
        let daemon = FakeCloudDaemon()
        await daemon.answerOps(creating: "conv_mixed")
        let source = CloudSourceHarness.connected(to: daemon)
        let intent = HomeIntent(key: IdempotencyKey("mixed-1"),
                                op: .createGroup(title: "", participants: [Self.austin.id, Self.aziz.id], invites: [Self.leo]))
        let result = try await source.submit(intent)
        #expect(result.conversation == ConversationID("conv_mixed"))
        let ops = await daemon.ops
        try #require(ops.count == 2)
        guard case .create(_, let participants) = ops[0].op else { Issue.record("first op is \(ops[0].op)"); return }
        #expect(participants.count == 3)
        #expect(ops[0].conversation == nil)
        #expect(ops[0].idempotencyKey == "mixed-1")
        guard case .createInvite(let address, _, _) = ops[1].op else { Issue.record("second op is \(ops[1].op)"); return }
        #expect(address == CloudHomeMapping.address(Self.leo))
        #expect(ops[1].conversation == "conv_mixed")
        #expect(ops[1].idempotencyKey == "mixed-1:invite:0")
    }
}
