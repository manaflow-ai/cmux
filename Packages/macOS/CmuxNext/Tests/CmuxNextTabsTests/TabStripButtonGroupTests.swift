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

    /// Center of the + button in strip coordinates.
    private func newTabCenter(_ h: Harness) -> CGPoint {
        let frame = h.strip.newTabButton.frame
        return h.strip.newTabButton.superview!.convert(CGPoint(x: frame.midX, y: frame.midY), to: h.strip)
    }

    @Test func plusClickOpensATabAtOnce() {
        let h = Harness(buttons: [])
        var asked: [TabContextTarget] = []
        h.strip.contextMenuProvider = { asked.append($0); return nil }
        h.strip.pressedNewTab = true
        #expect(h.strip.endNewTabPress(at: newTabCenter(h)))
        #expect(h.intents == [.newTab(after: nil)])
        #expect(asked.isEmpty, "a click never shows the engine menu")
    }

    @Test func plusHoldShowsTheMenuAndOpensNoTab() async {
        let h = Harness(buttons: [])
        var asked: [TabContextTarget] = []
        h.strip.contextMenuProvider = { asked.append($0); return nil }
        h.strip.groups.sleep = { _ in }
        h.strip.pressedNewTab = true
        h.strip.startNewTabHold()
        for _ in 0..<50 where asked.isEmpty { await Task.yield() }
        #expect(asked == [.newTabButton])
        h.strip.endNewTabPress(at: newTabCenter(h))
        #expect(h.intents.isEmpty)
    }

    static let cluster = [
        TabStripButton(id: "cmux.split", icon: .symbol("square.split.2x1"), toolTip: "Split Right (⌘D)",
                       accessibilityLabel: "Split Right", menu: .secondary),
        TabStripButton(id: "cmux.more", icon: .symbol("ellipsis"), toolTip: "More", accessibilityLabel: "More", menu: .primary),
    ]

    @Test func optionReleaseSendsTheAlternate() {
        let h = Harness(buttons: Self.cluster)
        h.strip.pendingTrailingPress = 0
        #expect(h.strip.endTrailingButtonPress(at: h.center(of: 0), modifiers: .option))
        h.strip.pendingTrailingPress = 0
        #expect(h.strip.endTrailingButtonPress(at: h.center(of: 0)))
        #expect(h.intents == [.trailingButtonAlternate("cmux.split"), .trailingButton("cmux.split")])
    }

    @Test func aPrimaryMenuButtonOpensItsMenuAndRunsNothing() throws {
        let h = Harness(buttons: Self.cluster)
        var asked: [TabContextTarget] = []
        // An empty menu is never shown, so the test does not block in menu tracking.
        h.strip.contextMenuProvider = { asked.append($0); return NSMenu() }
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: h.strip.convert(h.center(of: 1), to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        h.strip.mouseDown(with: event)
        #expect(asked == [.trailingButton("cmux.more")])
        #expect(h.strip.pendingTrailingPress == nil)
        let element = try #require(h.strip.buttonGroup.accessibilityChildren()?.last as? NSAccessibilityElement)
        #expect(element.accessibilityPerformPress())
        #expect(asked == [.trailingButton("cmux.more"), .trailingButton("cmux.more")])
        #expect(h.intents.isEmpty)
    }

    @Test func aReleaseEndsItsHoldSoAQuickRepressGetsAFullHold() async {
        let h = Harness(buttons: Self.cluster)
        var asked: [TabContextTarget] = []
        h.strip.contextMenuProvider = { asked.append($0); return NSMenu() }
        // Each hold sleeps until its own gate opens.
        let holds = Gates()
        h.strip.groups.sleep = { _ in
            let (gate, open) = AsyncStream<Void>.makeStream()
            await holds.add(open)
            for await _ in gate {}
        }
        var gates: [AsyncStream<Void>.Continuation] { holds.list }
        h.strip.trailingMenus.pressDown(0)
        for _ in 0..<50 where gates.isEmpty { await Task.yield() }
        #expect(h.strip.endTrailingButtonPress(at: h.center(of: 0)))
        h.strip.trailingMenus.pressDown(0)
        for _ in 0..<50 where gates.count < 2 { await Task.yield() }
        // The first press's hold ends now; it must not open the second press's menu.
        gates.first?.finish()
        for _ in 0..<50 { await Task.yield() }
        #expect(asked.isEmpty)
        #expect(h.strip.pendingTrailingPress == 0)
        #expect(h.intents == [.trailingButton("cmux.split")])
        gates.last?.finish()
        for _ in 0..<50 where asked.isEmpty { await Task.yield() }
        #expect(asked == [.trailingButton("cmux.split")])
    }

    @MainActor final class Gates {
        var list: [AsyncStream<Void>.Continuation] = []
        func add(_ gate: AsyncStream<Void>.Continuation) { list.append(gate) }
    }

    @Test func aHoldDraggedOffTheButtonShowsNoMenu() async {
        let h = Harness(buttons: Self.cluster)
        var asked: [TabContextTarget] = []
        h.strip.contextMenuProvider = { asked.append($0); return NSMenu() }
        h.strip.groups.sleep = { _ in }
        h.strip.trailingMenus.pressDown(0)
        #expect(h.strip.trackTrailingButtonDrag(at: h.center(of: 1)))
        for _ in 0..<50 { await Task.yield() }
        #expect(asked.isEmpty)
        #expect(h.strip.endTrailingButtonPress(at: h.center(of: 1)))
        #expect(h.intents.isEmpty)
    }

    @Test func holdingASecondaryMenuButtonShowsItsMenuInsteadOfRunning() async {
        let h = Harness(buttons: Self.cluster)
        var asked: [TabContextTarget] = []
        h.strip.contextMenuProvider = { asked.append($0); return NSMenu() }
        h.strip.groups.sleep = { _ in }
        h.strip.pendingTrailingPress = 0
        h.strip.trailingMenus.startHold(0)
        for _ in 0..<50 where asked.isEmpty { await Task.yield() }
        #expect(asked == [.trailingButton("cmux.split")])
        #expect(!h.strip.endTrailingButtonPress(at: h.center(of: 0)))
        #expect(h.intents.isEmpty)
    }
}
