import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextTabs

/// User feedback on nxdog9: the trailing buttons (new terminal, new
/// browser, splits) show only while the pointer is over the tab strip,
/// while a menu the strip opened is up, or while VoiceOver focuses one of
/// them. The tab layout never changes when they appear.
@MainActor @Suite struct TabStripButtonRevealTests {
    final class Harness {
        let window: NSWindow
        let model: TabStripModel
        let strip: TabStripView
        var intents: [TabStripIntent] = []

        init() {
            DesignSettings.shared.animationSpeed = .off
            model = TabStripModel(
                tabs: [TabItem(id: TabID("t0"), title: "Tab"), TabItem(id: TabID("t1"), title: "Other")],
                selectedID: TabID("t0"),
                trailingButtons: TabStripButtonGroupTests.splits
            )
            strip = TabStripView(model: model)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 60), styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            strip.frame = NSRect(x: 0, y: 0, width: 600, height: TabStripView.preferredHeight)
            window.contentView!.addSubview(strip)
            model.intentHandler = { [unowned self] in self.intents.append($0) }
            strip.sync(fromModel: true)
            strip.layoutSubtreeIfNeeded()
        }

        var buttonsVisible: Bool { strip.buttonGroup.alphaValue > 0 }
        var plusVisible: Bool { strip.newTabButton.alphaValue > 0 }

        /// Window coordinates of a strip point (the strip is flipped).
        func windowPoint(_ point: CGPoint) -> NSPoint { strip.convert(point, to: nil) }

        func enter(at point: CGPoint = CGPoint(x: 300, y: 10)) {
            let event = NSEvent.enterExitEvent(with: .mouseEntered, location: windowPoint(point), modifierFlags: [],
                                               timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                               eventNumber: 0, trackingNumber: 0, userData: nil)!
            strip.mouseEntered(with: event)
        }

        func move(to point: CGPoint) {
            let event = NSEvent.mouseEvent(with: .mouseMoved, location: windowPoint(point), modifierFlags: [], timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
            strip.mouseMoved(with: event)
        }

        func exit() {
            let event = NSEvent.enterExitEvent(with: .mouseExited, location: windowPoint(CGPoint(x: 300, y: 200)), modifierFlags: [],
                                               timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                               eventNumber: 0, trackingNumber: 0, userData: nil)!
            strip.mouseExited(with: event)
        }
    }

    @Test func buttonsAreHiddenUntilThePointerIsOverTheStrip() {
        let h = Harness()
        #expect(!h.buttonsVisible)
        h.enter()
        #expect(h.buttonsVisible)
        h.exit()
        #expect(!h.buttonsVisible)
    }

    @Test func movingOverTheStripRevealsThemWithoutAnEnterEvent() {
        let h = Harness()
        h.move(to: CGPoint(x: 100, y: 10))
        #expect(h.buttonsVisible)
    }

    @Test func revealingTheButtonsNeverMovesTheTabs() {
        let h = Harness()
        let clip = h.strip.tabsClip.frame
        let tabs = h.strip.cells.mapValues(\.frame)
        h.enter()
        h.strip.layoutSubtreeIfNeeded()
        #expect(h.strip.tabsClip.frame == clip)
        #expect(h.strip.cells.mapValues(\.frame) == tabs)
        h.exit()
        h.strip.layoutSubtreeIfNeeded()
        #expect(h.strip.tabsClip.frame == clip)
    }

    @Test func anOpenStripMenuKeepsThemUntilItCloses() throws {
        let h = Harness()
        let menu = NSMenu()
        menu.addItem(withTitle: "Item", action: nil, keyEquivalent: "")
        h.strip.contextMenuProvider = { _ in menu }
        h.enter()
        let click = NSEvent.mouseEvent(with: .rightMouseDown, location: h.windowPoint(CGPoint(x: 50, y: 10)), modifierFlags: [],
                                       timestamp: 0, windowNumber: h.window.windowNumber, context: nil, eventNumber: 0,
                                       clickCount: 1, pressure: 1)!
        let shown = try #require(h.strip.menu(for: click))
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: shown)
        h.exit()
        #expect(h.buttonsVisible, "the pointer left for the menu; the buttons stay")
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: shown)
        #expect(!h.buttonsVisible)
    }

    @Test func accessibilityFocusRevealsThemAndPressStillWorksWhileHidden() throws {
        let h = Harness()
        let element = try #require(h.strip.buttonGroup.accessibilityChildren()?.first as? NSAccessibilityElement)
        #expect(element.accessibilityPerformPress(), "reachable from assistive tech while hidden")
        #expect(h.intents == [.trailingButton("cmux.splitRight")])
        element.setAccessibilityFocused(true)
        #expect(h.buttonsVisible)
        element.setAccessibilityFocused(false)
        #expect(!h.buttonsVisible)
    }

    /// R120: the plus button shows only while the tab bar is hovered, in
    /// place, through the one hover-reveal mechanism (HoverReveal).
    @Test func thePlusButtonRevealsOnlyOnHover() {
        let h = Harness()
        let frame = h.strip.newTabButton.frame
        #expect(!h.strip.newTabButton.isHidden)
        #expect(!h.plusVisible)
        h.enter()
        #expect(h.plusVisible)
        #expect(h.strip.newTabButton.frame == frame)
        h.exit()
        #expect(!h.plusVisible)
        #expect(HoverReveal.owner(of: h.strip.newTabButton) === HoverReveal.owner(of: h.strip.buttonGroup))
    }

    /// `tabs.plusButton` = always keeps the plus shown at rest while the
    /// trailing buttons still reveal on hover; back to hover hides it again.
    @Test func plusButtonAlwaysKeepsThePlusShown() {
        let saved = DesignSettings.shared.plusButton
        defer { DesignSettings.shared.plusButton = saved }
        DesignSettings.shared.plusButton = .always
        let h = Harness()
        #expect(h.plusVisible)
        #expect(!h.buttonsVisible)
        DesignSettings.shared.plusButton = .hover
        h.strip.applyPlusButtonMode()
        #expect(!h.plusVisible)
    }
}
