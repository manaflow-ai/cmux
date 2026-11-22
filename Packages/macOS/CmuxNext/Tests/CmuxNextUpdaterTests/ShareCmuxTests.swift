import AppKit
import Testing
@testable import CmuxNextUpdater

/// "Share cmux" (cx-7py7): a centered modal with a title, one line, an
/// editable message that carries the plain public download link, and Copy
/// Link, which copies the message as shown (edits included) and turns into
/// "Copied". The x and Escape close it. No referral tracking.
@MainActor
@Suite struct ShareCmuxTests {
    /// Records what Copy Link writes (a fleet step has no pasteboard server;
    /// the real-app proof checks the general pasteboard).
    private final class Clipboard {
        var text: String?
    }

    @Test func theMessageCarriesThePlainDownloadLink() {
        let message = ShareCmuxView.defaultMessage
        #expect(ShareCmuxView.downloadURL.absoluteString == "https://cmux.com/download")
        #expect(message.hasSuffix("\n\nhttps://cmux.com/download"))
        #expect(!message.contains("?"), "no referral or tracking query")
    }

    @Test func copyLinkWritesTheMessageAndShowsCopied() {
        let board = Clipboard()
        let view = ShareCmuxView { board.text = $0 }
        #expect(view.messageText == ShareCmuxView.defaultMessage)
        #expect(view.copyButton.button.title == "Copy Link")
        view.copyButton.performClick(nil)
        #expect(board.text == ShareCmuxView.defaultMessage)
        #expect(view.copyButton.button.title == "Copied")
    }

    @Test func copyLinkCopiesTheEditedMessage() {
        let board = Clipboard()
        let view = ShareCmuxView { board.text = $0 }
        view.messageText = "Try this terminal: https://cmux.com/download"
        view.copyButton.performClick(nil)
        #expect(board.text == "Try this terminal: https://cmux.com/download")
    }

    @Test func theCloseButtonAndEscapeClose() {
        let view = ShareCmuxView { _ in }
        var closed = 0
        view.onClose = { closed += 1 }
        view.closeButton.performClick(nil)
        view.cancelOperation(nil)
        #expect(closed == 2)
        #expect(view.closeButton.accessibilityLabel() == "Close")
        #expect(view.messageView.accessibilityLabel() == "Message")
    }

    @Test func theModalShowsItsTitleAndLine() {
        let view = ShareCmuxView { _ in }
        view.layoutSubtreeIfNeeded()
        #expect(view.shownText == ["Share cmux with a Friend", "Send this message with the download link to a friend."])
        #expect(view.frame.width > 0 && view.frame.height > 0)
    }
}
