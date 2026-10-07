import AppKit
import Testing
@testable import CmuxNextTabs

/// An overflowing saved-groups bar scrolls horizontally instead of clipping
/// its last chips.
@MainActor @Suite struct SavedGroupsBarScrollTests {
    func makeBar(groups: Int, width: CGFloat) -> (NSWindow, SavedGroupsBarView) {
        let items = (0..<groups).map { i in
            SavedTabGroupItem(id: TabGroupID("g\(i)"), name: "Saved group \(i)", colorToken: .grey, tabCount: 3)
        }
        let bar = SavedGroupsBarView(model: SavedGroupsBarModel(groups: items))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 40), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        bar.frame = NSRect(x: 0, y: 0, width: width, height: SavedGroupsBarView.preferredHeight)
        window.contentView!.addSubview(bar)
        bar.layoutSubtreeIfNeeded()
        return (window, bar)
    }

    func frames(_ bar: SavedGroupsBarView) -> [CGRect] {
        (bar.accessibilityChildren() ?? []).compactMap { ($0 as? NSAccessibilityElement)?.accessibilityFrameInParentSpace() }
    }

    func scrollEvent(deltaX: Int32) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: deltaX, wheel3: 0)!
        return NSEvent(cgEvent: cg)!
    }

    @Test func overflowingBarScrollsToRevealTheLastChip() throws {
        let (window, bar) = makeBar(groups: 20, width: 300)
        _ = window
        let before = try #require(frames(bar).last)
        #expect(before.maxX > bar.bounds.width)
        for _ in 0..<200 { bar.scrollWheel(with: scrollEvent(deltaX: -40)) }
        bar.layoutSubtreeIfNeeded()
        let after = try #require(frames(bar).last)
        #expect(after.maxX <= bar.bounds.width + 0.5)
        #expect(after.maxX > bar.bounds.width - 40)
    }

    @Test func barThatFitsDoesNotScroll() throws {
        let (window, bar) = makeBar(groups: 2, width: 600)
        _ = window
        let before = try #require(frames(bar).first)
        bar.scrollWheel(with: scrollEvent(deltaX: -80))
        bar.layoutSubtreeIfNeeded()
        #expect(frames(bar).first == before)
    }
}
