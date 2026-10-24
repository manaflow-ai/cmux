import AppKit
@testable import CmuxNextDesign
import Testing

/// Native page-popup row updates stay in place for live tooltip labels while structural menu
/// updates keep their existing rebuild behavior.
@MainActor @Suite struct WebPopupRowsTests {
    @Test func aTooltipLabelUpdateKeepsItsNativeRowView() throws {
        let rows = WebPopupRows(onPick: { _ in }, onHover: { _ in })
        rows.plain = true
        let first = WebPopupHost.Item(id: "0", label: "needs_you_prior_art · Running · 2m40s · shell action",
                                      shortcut: nil, checked: false, disabled: false, separator: false)
        rows.update([first], highlighted: nil)
        let row = try #require(rows.subviews.compactMap { $0 as? PopupRowView }.first)

        let next = WebPopupHost.Item(id: first.id,
                                     label: "needs_you_prior_art · Running · 2m41s · shell action",
                                     shortcut: nil, checked: false, disabled: false, separator: false)
        rows.update([next], highlighted: nil)

        let updated = try #require(rows.subviews.compactMap { $0 as? PopupRowView }.first)
        #expect(updated === row)
        #expect(updated.titleLabel.stringValue == next.label)
        #expect(updated.accessibilityLabel() as? String == next.label)
    }

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

    @Test func aPlainModeChangeRebuildsIdenticalItems() throws {
        let rows = WebPopupRows(onPick: { _ in }, onHover: { _ in })
        let item = WebPopupHost.Item(id: "0", label: "Same", shortcut: nil, checked: false, disabled: false, separator: false)
        rows.plain = true
        rows.update([item], highlighted: nil)
        let plain = try #require(rows.subviews.compactMap { $0 as? PopupRowView }.first)

        rows.plain = false
        rows.update([item], highlighted: nil)

        let menu = try #require(rows.subviews.compactMap { $0 as? PopupRowView }.first)
        #expect(menu !== plain)
        #expect(menu.rowLayout.leadingColumn == 15)
    }
}
