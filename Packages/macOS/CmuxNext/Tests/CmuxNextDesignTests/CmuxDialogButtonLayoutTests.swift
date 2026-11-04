import AppKit
@testable import CmuxNextDesign
import Testing

/// A dialog's buttons all show. One row has a fixed width, and its stack view drops the buttons
/// that do not fit, so the Computer Use approval card (four answers) drew no Deny on a capture
/// mini. `.column` lays out one full-width button per line, every one inside the dialog.
@MainActor @Suite struct CmuxDialogButtonLayoutTests {
    private static let buttons = [
        CmuxDialogButton(id: "once", title: "Allow Once", role: .normal),
        CmuxDialogButton(id: "session", title: "Allow for This Session", role: .normal),
        CmuxDialogButton(id: "always", title: "Always Allow Safari", role: .normal),
        CmuxDialogButton(id: "deny", title: "Deny", role: .cancel),
    ]

    /// The dialog laid out in a window, and the buttons that show inside its bounds.
    private static func shown(_ layout: CmuxDialogSpec.ButtonLayout) throws -> (all: Int, shown: Set<String>) {
        let dialog = CmuxDialogView(spec: CmuxDialogSpec(title: "Allow Claude to use Safari?",
                                                         lines: ["Claude in api-server wants to see and use this app."],
                                                         buttons: buttons, buttonLayout: layout))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = try #require(window.contentView)
        root.addSubview(dialog)
        root.layoutSubtreeIfNeeded()
        let bounds = dialog.bounds
        let shown = dialog.buttonViews.filter { view in
            guard view.superview != nil, !view.isHiddenOrHasHiddenAncestor else { return false }
            let frame = view.convert(view.bounds, to: dialog)
            return frame.width > 1 && frame.height > 1 && bounds.contains(frame.insetBy(dx: 0.5, dy: 0.5))
        }
        return (dialog.buttonViews.count, Set(shown.map(\.button.id)))
    }

    @Test func aColumnShowsEveryButtonInsideTheDialog() throws {
        let column = try Self.shown(.column)
        #expect(column.all == 4)
        #expect(column.shown == ["once", "session", "always", "deny"])
    }

    @Test func aColumnStacksTopToBottomInOrder() throws {
        let dialog = CmuxDialogView(spec: CmuxDialogSpec(title: "T", buttons: Self.buttons, buttonLayout: .column))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        try #require(window.contentView).addSubview(dialog)
        window.contentView?.layoutSubtreeIfNeeded()
        let tops = dialog.buttonViews.map { $0.convert($0.bounds, to: nil).maxY }
        #expect(tops == tops.sorted(by: >), "first button on top")
    }
}
