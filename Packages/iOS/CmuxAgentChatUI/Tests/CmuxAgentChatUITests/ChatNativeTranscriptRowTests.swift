import CmuxAgentChat
import Foundation
import Testing

#if canImport(UIKit)
import UIKit

@testable import CmuxAgentChatUI

@Suite("Native transcript rows")
@MainActor
struct ChatNativeTranscriptRowTests {
    @Test("tool row exposes state and routes its primary action once")
    func toolRowAction() {
        var detailCount = 0
        let view = ChatToolUseRowView(
            toolUse: ChatToolUse(
                toolName: "Read",
                summary: "Read Sources/App.swift",
                status: .succeeded
            ),
            rowID: "msg-42",
            onShowDetail: { detailCount += 1 }
        )

        #expect(view.accessibilityIdentifier == "ChatToolUseToggle-msg-42")
        #expect(view.accessibilityLabel?.contains("Succeeded") == true)
        view.sendActions(for: .primaryActionTriggered)
        #expect(detailCount == 1)
    }

    @Test("thought row retains its stable automation route")
    func thoughtRowAction() {
        var detailCount = 0
        let view = ChatThoughtRowView(rowID: "msg-7") {
            detailCount += 1
        }

        #expect(view.accessibilityIdentifier == "ChatThoughtDetail-msg-7")
        view.sendActions(for: .primaryActionTriggered)
        #expect(detailCount == 1)
    }

    @Test("date header remains a localized accessibility landmark")
    func dateHeader() throws {
        let view = ChatDateHeaderView(day: Date(timeIntervalSince1970: 0))
        let pill = try #require(view.subviews.first)
        let label = try #require(pill.subviews.compactMap { $0 as? UILabel }.first)

        #expect(label.accessibilityIdentifier == "ChatDateHeader")
        #expect(label.text?.isEmpty == false)
    }

    @Test("elapsed working labels preserve compact units")
    func elapsedLabels() {
        #expect(ChatTypingIndicatorView.elapsedLabel(seconds: 5).contains("5"))
        #expect(ChatTypingIndicatorView.elapsedLabel(seconds: 83).contains("1"))
        #expect(ChatTypingIndicatorView.elapsedLabel(seconds: 3_720).contains("1"))
    }
}
#endif
