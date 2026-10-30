import CmuxHomeCore
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
        let outcome = await composer.start([.contact(Self.austin), .contact(Self.aziz), .address(Self.leo)], title: "")
        #expect(outcome == .opened(created))
        #expect(outcome.message == nil)
        #expect(ops.count == 1)
    }
}
