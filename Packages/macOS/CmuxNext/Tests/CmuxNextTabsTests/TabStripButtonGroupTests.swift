import AppKit
import Testing
@testable import CmuxNextTabs

/// The trailing button group: layout at the trailing edge, live updates
/// from the model, and clicks sent as `trailingButton` intents.
@MainActor @Suite struct TabStripButtonGroupTests {
    final class Harness {
        let window: NSWindow
        let model: TabStripModel
        let strip: TabStripView
        var intents: [TabStripIntent] = []

        init(buttons: [TabStripButton]) {
            model = TabStripModel(tabs: [TabItem(id: TabID("t0"), title: "Tab")], selectedID: TabID("t0"), trailingButtons: buttons)
            strip = TabStripView(model: model)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 60), styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            strip.frame = NSRect(x: 0, y: 0, width: 600, height: TabStripView.preferredHeight)
            window.contentView!.addSubview(strip)
            model.intentHandler = { [unowned self] in self.intents.append($0) }
            strip.sync(fromModel: true)
            strip.layoutSubtreeIfNeeded()
        }

        /// Center of button `index` in strip coordinates.
        func center(of index: Int) -> CGPoint {
            let frame = strip.buttonGroup.buttonFrames()[index]
            return strip.buttonGroup.convert(CGPoint(x: frame.midX, y: frame.midY), to: strip)
        }
    }

    static let splits = [
        TabStripButton(id: "cmux.splitRight", icon: .symbol("square.split.2x1"), toolTip: "Split Right (⌘D)", accessibilityLabel: "Split Right"),
        TabStripButton(id: "cmux.splitDown", icon: .symbol("square.split.1x2"), toolTip: "Split Down (⇧⌘D)", accessibilityLabel: "Split Down"),
    ]

    @Test func groupSitsAtTheTrailingEdgeAndShrinksTheViewport() {
        let h = Harness(buttons: Self.splits)
        let metrics = h.strip.metrics
        let width = TabStripButtonGroupView.width(for: 2, metrics: metrics)
        #expect(!h.strip.buttonGroup.isHidden)
        #expect(h.strip.buttonGroup.frame.maxX == 600 - metrics.stripHorizontalPadding)
        #expect(h.strip.buttonGroup.frame.width == width)
        #expect(h.strip.tabsClip.frame.width == 600 - 2 * metrics.stripHorizontalPadding - metrics.newTabButtonWidth - width)
        #expect(h.strip.trailingButtonIndex(at: h.center(of: 1)) == 1)
        #expect(h.strip.buttonGroup.accessibilityChildren()?.count == 2)
    }

    @Test func noButtonsHidesTheGroup() {
        let h = Harness(buttons: [])
        #expect(h.strip.buttonGroup.isHidden)
        #expect(h.strip.trailingGroupWidth == 0)
        #expect(h.strip.trailingButtonIndex(at: CGPoint(x: 590, y: 10)) == nil)
    }

    @Test func modelChangesUpdateTheGroup() {
        let h = Harness(buttons: [])
        h.model.trailingButtons = Self.splits
        h.strip.sync(fromModel: true)
        h.strip.layoutSubtreeIfNeeded()
        #expect(h.strip.buttonGroup.buttons == Self.splits)
        #expect(!h.strip.buttonGroup.isHidden)
        h.model.trailingButtons = Array(Self.splits.prefix(1))
        h.strip.sync(fromModel: true)
        h.strip.layoutSubtreeIfNeeded()
        #expect(h.strip.buttonGroup.buttonFrames().count == 1)
    }

    @Test func releaseOnTheSameButtonSendsItsIntent() {
        let h = Harness(buttons: Self.splits)
        h.strip.pendingTrailingPress = 1
        #expect(h.strip.trackTrailingButtonDrag(at: h.center(of: 0)))
        #expect(h.strip.buttonGroup.pressedIndex == nil)
        #expect(h.strip.endTrailingButtonPress(at: h.center(of: 0)))
        #expect(h.intents.isEmpty)
        h.strip.pendingTrailingPress = 1
        #expect(h.strip.endTrailingButtonPress(at: h.center(of: 1)))
        #expect(h.intents == [.trailingButton("cmux.splitDown")])
        #expect(!h.strip.endTrailingButtonPress(at: h.center(of: 1)))
    }

    @Test func accessibilityPressSendsTheIntent() throws {
        let h = Harness(buttons: Self.splits)
        let element = try #require(h.strip.buttonGroup.accessibilityChildren()?.first as? NSAccessibilityElement)
        #expect(element.accessibilityPerformPress())
        #expect(h.intents == [.trailingButton("cmux.splitRight")])
    }
}
