import AppKit
import Testing
@testable import CmuxNextTabs

/// A pinned tab is icon-only (Chrome parity), so a pinned tab without an
/// icon of its own (a plain terminal) draws a pin mark instead of an empty
/// pill (nxdog63-v2: "a pinned tab shows no pin mark").
@MainActor @Suite struct PinnedTabMarkTests {
    @Test func aPinnedTabWithoutAnIconDrawsAPinMark() {
        var item = TabItem(id: "a", title: "zsh", icon: .none)
        #expect(TabCell(item: item).iconLayer.contents == nil, "an unpinned tab without an icon draws no glyph")
        item.isPinned = true
        #expect(TabCell(item: item).iconLayer.contents != nil)
    }
}
