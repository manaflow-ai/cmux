import CmuxConversationCore
import CmuxMobileNotifications
import Foundation
import Testing
@testable import CmuxMobileLive

/// Chief's conversation as the notification long look gets it (`PushSnapshots.chiefMessages`).
@MainActor
@Suite struct PushChiefSnapshotTests {
    func message(_ id: String, from sender: String, _ text: String, unsent: Bool = false, scheduled: Bool = false,
                 attachments: [ConversationAttachment] = []) -> ConversationMessage {
        ConversationMessage(id: id, seq: scheduled ? nil : 1, clientMessageID: nil, senderID: sender, sentAt: Date(), text: text,
                            unsentAt: unsent ? Date() : nil, attachments: attachments, scheduledAt: scheduled ? Date() : nil)
    }

    @Test func chiefsMessagesAreTheAgentsAndThePersonsAreTheUsers() {
        let photo = ConversationAttachment(id: "p", kind: .image, width: 1, height: 1, url: nil)
        let messages = PushSnapshots.chiefMessages([
            message("1", from: "user_local", "start an agent"),
            message("2", from: "agent_mux", "Started."),
            message("3", from: "user_local", "oops", unsent: true),
            message("4", from: "user_local", "later", scheduled: true),
            message("5", from: "user_local", "", attachments: [photo]),
        ], chiefID: "agent_mux")
        #expect(messages == [
            .init(role: .user, text: "start an agent"),
            .init(role: .agent, text: "Started."),
            .init(role: .user, text: "Photo"),
        ])
    }
}
