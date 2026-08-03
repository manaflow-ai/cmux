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

    func testTextChangeCallbackReceivesEditedPlainText() {
        let editor = FeedbackComposerMessageEditorView(frame: .zero)
        var receivedText: String?
        editor.onTextChange = { receivedText = $0 }

        editor.textView.string = "Native feedback"
        NotificationCenter.default.post(
            name: NSText.didChangeNotification,
            object: editor.textView
        )

        XCTAssertEqual(receivedText, "Native feedback")
    }

    func testComposerEnablesSendOnlyAfterValidEmailAndMessage() throws {
        let defaultsName = "CmuxFeedbackTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let controller = SidebarFeedbackComposerSheet(userDefaults: defaults)
        controller.loadViewIfNeeded()

        let emailField = try XCTUnwrap(
            descendant(of: controller.view, identifier: "SidebarFeedbackEmailField") as? NSTextField
        )
        let messageEditor = try XCTUnwrap(
            descendants(of: controller.view)
                .compactMap { $0 as? NSTextView }
                .first { $0.accessibilityIdentifier() == "SidebarFeedbackMessageEditor" }
        )
        let sendButton = try XCTUnwrap(
            descendant(of: controller.view, identifier: "SidebarFeedbackSendButton") as? NSButton
        )

        XCTAssertFalse(sendButton.isEnabled)
        emailField.stringValue = "person@example.com"
        controller.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: emailField)
        )
        XCTAssertFalse(sendButton.isEnabled)

        messageEditor.string = "The native composer works."
        NotificationCenter.default.post(name: NSText.didChangeNotification, object: messageEditor)

        XCTAssertTrue(sendButton.isEnabled)
        XCTAssertEqual(defaults.string(forKey: "sidebarHelpFeedbackEmail"), "person@example.com")
    }

    private func descendant(of root: NSView, identifier: String) -> NSView? {
        descendants(of: root).first { $0.accessibilityIdentifier() == identifier }
    }

    private func descendants(of root: NSView) -> [NSView] {
        root.subviews + root.subviews.flatMap(descendants(of:))
    }
}
