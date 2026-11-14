import AppKit
@testable import CmuxNextDesign
import Testing

/// A toast's action button shows its whole title, never clipped or cut to an ellipsis, beside the message and
/// before close (Leo, 2026-11-03, on "Restart cmux-tui to use new features   Restart cmux-tui…": "aren't these
/// all kinda awkward looking").
@MainActor
struct CmuxToastActionFitTests {
    @Test(arguments: ["Restart", "Details", "Reopen Closed Workspace", "Restart cmux-tui on a-long-host-name…"])
    func theActionTitleIsNeverClipped(title: String) throws {
        let toast = CmuxToast(id: "fit", message: "Update ready for cmux-tui on a-long-host-name",
                              action: CmuxToast.Action(title: title), duration: CmuxToast.untilClosed)
        let view = CmuxToastView(toast: toast)
        view.frame.size = view.fittingSize
        view.layoutSubtreeIfNeeded()
        let button = try #require(view.actionButton)
        let frame = button.convert(button.bounds, to: view)
        let text = ceil(button.attributedTitle.size().width)
        #expect(frame.width >= text + CmuxToastButton.titlePadding * 2 - 0.5,
                "\"\(title)\" is \(frame.width) pt wide for \(text) pt of text")
        let cellWidth = try #require(button.cell).cellSize.width
        #expect(frame.width >= ceil(cellWidth) - 0.5, "\"\(title)\" is narrower than its cell draws it: \(frame.width) < \(cellWidth)")
        #expect(view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\"\(title)\" at \(frame) is outside the toast \(view.bounds)")
        let close = view.closeButton.convert(view.closeButton.bounds, to: view)
        #expect(frame.maxX <= close.minX + 0.5, "\"\(title)\" runs under close")
        let message = try #require(view.messageLabel)
        #expect(message.convert(message.bounds, to: view).maxX <= frame.minX + 0.5, "the message runs under \"\(title)\"")
    }
}
