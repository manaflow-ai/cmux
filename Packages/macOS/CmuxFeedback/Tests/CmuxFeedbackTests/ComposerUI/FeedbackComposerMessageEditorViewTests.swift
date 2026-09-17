import AppKit
import XCTest

@testable import CmuxFeedback

@MainActor
final class FeedbackComposerMessageEditorViewTests: XCTestCase {
    func testLongMessageCreatesScrollableDocumentContent() {
        let editor = FeedbackComposerMessageEditorView(
            frame: NSRect(x: 0, y: 0, width: 360, height: 120)
        )
        editor.placeholder = "Message"
        editor.layoutSubtreeIfNeeded()

        editor.textView.string = (0..<80)
            .map { "feedback line \($0)" }
            .joined(separator: "\n")
        editor.refreshTextLayout()
        editor.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(
            editor.textView.frame.height,
            editor.scrollView.contentSize.height + 40
        )
    }

    func testTrailingBlankLineContributesToScrollableDocumentHeight() {
        let editor = FeedbackComposerMessageEditorView(
            frame: NSRect(x: 0, y: 0, width: 360, height: 120)
        )
        editor.layoutSubtreeIfNeeded()

        let messageWithoutTrailingBlankLine = (0..<20)
            .map { "feedback line \($0)" }
            .joined(separator: "\n")
        editor.textView.string = messageWithoutTrailingBlankLine
        editor.refreshTextLayout()
        let heightWithoutTrailingBlankLine = editor.textView.frame.height

        editor.textView.string = messageWithoutTrailingBlankLine + "\n"
        editor.refreshTextLayout()

        XCTAssertGreaterThan(
            editor.textView.frame.height,
            heightWithoutTrailingBlankLine + 5
        )
    }
}
