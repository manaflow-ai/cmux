import CmuxHomeCore
import CmuxNextHome
@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// New Message with several people or addresses (a group chat) whose create the cloud owner did
/// not answer: the store keeps it for a resend and throws `HomeSendState`. The sheet must say the
/// cloud did not answer, never the enum case name ("That didn’t work: pendingResend"), and never
/// "Nothing was sent" (the resend may still make the group).
@MainActor
@Suite struct HomeComposerUnansweredTests {
    private static let addresses: [HomeRecipient] = ["austin@manaflow.ai", "leo@cmux.com", "aziz@manaflow.ai"]
        .compactMap { ContactAddress.parse($0) }.map(HomeRecipient.address)
    private static let people: [HomeRecipient] = ["austin", "leo", "aziz"]
        .map { HomeRecipient.contact(HomeContact(id: ParticipantID($0), name: $0, source: .team)) }

    private static func outcome(_ recipients: [HomeRecipient], throwing state: HomeSendState) async -> HomeComposeOutcome {
        let composer = HomeComposer(perform: { _ in throw state }, describe: { String(describing: $0) })
        return await composer.start(recipients, title: "", firstMessage: [.text("hi")])
    }

    @Test(arguments: [HomeSendState.pendingResend, .unanswered], [true, false])
    func anUnansweredGroupStartSaysTheCloudDidNotAnswer(_ state: HomeSendState, addresses: Bool) async throws {
        let outcome = await Self.outcome(addresses ? Self.addresses : Self.people, throwing: state)
        let message = try #require(outcome.message)
        #expect(!message.contains(String(describing: state)))
        #expect(outcome != .offline)
        #expect(outcome != .refused(""))
    }
}
