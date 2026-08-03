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

    @Test("failed pending send keeps independent retry and discard actions")
    func pendingRecoveryActions() throws {
        var retried: [String] = []
        var discarded: [String] = []
        let view = ChatPendingBubbleView(
            pending: ChatPendingOutbound(
                id: "pending-9",
                text: "Push the branch",
                createdAt: .now,
                delivery: .failed("offline")
            ),
            actions: ChatRowActions(
                retryPending: { retried.append($0) },
                discardPending: { discarded.append($0) }
            )
        )
        let buttons = view.descendants.compactMap { $0 as? UIButton }
        let retry = try #require(buttons.first { $0.accessibilityIdentifier == "ChatPendingRetry" })
        let discard = try #require(buttons.first { $0.accessibilityIdentifier == "ChatPendingDiscard" })

        retry.sendActions(for: .primaryActionTriggered)
        discard.sendActions(for: .primaryActionTriggered)
        #expect(retried == ["pending-9"])
        #expect(discarded == ["pending-9"])
    }

    @Test("terminal row routes detail and interactive escape hatch separately")
    func terminalActions() throws {
        var detailCount = 0
        let command = TerminalCommandBlockView(
            block: TerminalCommandBlock(
                id: 4,
                command: "swift build",
                output: "done",
                exitCode: 0,
                isRunning: false
            ),
            onOpenTerminal: {},
            onShowDetail: { detailCount += 1 }
        )
        command.sendActions(for: .primaryActionTriggered)
        #expect(detailCount == 1)

        var openCount = 0
        let interactive = TerminalCommandBlockView(
            block: TerminalCommandBlock(
                id: 5,
                command: "vim notes.md",
                isRunning: true,
                isInteractive: true
            ),
            onOpenTerminal: { openCount += 1 }
        )
        let open = try #require(
            interactive.descendants.compactMap { $0 as? UIButton }.first {
                $0.accessibilityIdentifier == "TerminalInteractiveOpenButton"
            }
        )
        open.sendActions(for: .primaryActionTriggered)
        #expect(openCount == 1)
    }
}

private extension UIView {
    var descendants: [UIView] {
        subviews + subviews.flatMap(\.descendants)
    }
}
#endif
