import AppKit
@testable import CmuxNextDesign
import Testing

/// A page menu's native rows stay in place when an update changes only its highlight.
@MainActor @Suite struct WebPopupRowsTests {
    @Test func anUnchangedMenuUpdateKeepsSeparatorAndRowViews() throws {
        let rows = WebPopupRows(onPick: { _ in }, onHover: { _ in })
        let items = [
            WebPopupHost.Item(id: "0", label: "First", shortcut: nil, checked: false, disabled: false, separator: false),
            WebPopupHost.Item(id: "1", label: "", shortcut: nil, checked: false, disabled: false, separator: true),
            WebPopupHost.Item(id: "2", label: "Second", shortcut: nil, checked: false, disabled: false, separator: false),
        ]
        rows.update(items, highlighted: nil)
        let views = rows.subviews

        rows.update(items, highlighted: "2")

        #expect(rows.subviews.count == views.count)
        for (updated, original) in zip(rows.subviews, views) { #expect(updated === original) }
    }
}
