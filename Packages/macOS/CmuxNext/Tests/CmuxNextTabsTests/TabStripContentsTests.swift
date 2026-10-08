import AppKit
import Testing
@testable import CmuxNextTabs

/// R46 (Lawrence 2026-10-03): a "www.google.com" chip showed to the right of
/// the "+" button next to the "Google" tab: the strip's location field
/// (PR #16718). It is removed; the browser's own address bar shows the
/// address. The strip shows its tabs and the "+" button, nothing else.
@MainActor @Suite struct TabStripContentsTests {
    @Test func aSelectedBrowserTabShowsOnlyTabsAndThePlusButton() {
        let tabs = [
            TabItem(id: TabID("google"), title: "Google", subtitle: "https://www.google.com/", icon: .symbol("globe")),
            TabItem(id: TabID("shell"), title: "zsh"),
        ]
        let model = TabStripModel(tabs: tabs, selectedID: TabID("google"))
        let strip = TabStripView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 60), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        strip.frame = NSRect(x: 0, y: 0, width: 900, height: TabStripView.preferredHeight)
        window.contentView?.addSubview(strip)
        strip.sync(fromModel: true)
        strip.layoutSubtreeIfNeeded()

        let children = strip.accessibilityChildren() ?? []
        #expect(children.count == tabs.count + 1)
        #expect(children.last as? NSView === strip.newTabButton)
        // Nothing visible sits right of "+": the strip has no trailing buttons.
        let plusEnd = strip.newTabButton.frame.maxX
        let after = strip.newTabButton.superview?.subviews.filter { view in
            !view.isHidden && view.alphaValue > 0 && view !== strip.newTabButton && view.frame.minX >= plusEnd && view.frame.width > 0
        } ?? []
        #expect(after.isEmpty, "views after +: \(after)")
    }
}
