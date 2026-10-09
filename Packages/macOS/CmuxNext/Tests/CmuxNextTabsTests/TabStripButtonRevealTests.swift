import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextTabs

/// R120 and nxdog9: the plus shows only while the pointer is over the tab
/// strip or while a menu the strip opened is up. The tab layout never
/// changes when it appears. The strip has no trailing buttons
/// (TAB-STRIP-TRAILING-BUTTONS-REMOVED).
@MainActor @Suite struct TabStripButtonRevealTests {
    final class Harness {
        let window: NSWindow
        let model: TabStripModel
        let strip: TabStripView
        var intents: [TabStripIntent] = []

        init() {
            model = TabStripModel(
                tabs: [TabItem(id: TabID("t0"), title: "Tab"), TabItem(id: TabID("t1"), title: "Other")],
                selectedID: TabID("t0")
            )
            strip = TabStripView(model: model)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 60), styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            strip.frame = NSRect(x: 0, y: 0, width: 600, height: TabStripView.preferredHeight)
            window.contentView.addSubview(strip)
            model.intentHandler = { [unowned self] in self.intents.append($0) }
            strip.sync(fromModel: true)
            strip.layoutSubtreeIfNeeded()
        }

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

    /// Runs `body` with a fresh harness and animations off, so alpha changes
    /// apply at once, and restores the speed before returning. Synchronous on
    /// the main actor: no other test runs while the speed is off.
    func withHarness(_ body: (Harness) throws -> Void) rethrows {
        let saved = DesignSettings.shared.animationSpeed
        defer { DesignSettings.shared.animationSpeed = saved }
        DesignSettings.shared.animationSpeed = .off
        try body(Harness())
    }

    /// `DesignSettings.shared` is process-wide and the package runs every
    /// test target in one process: a reveal test that turns animations off
    /// must turn them back on, or later motion tests (launch mark, spinners,
    /// palette scale) see `Motion.duration == 0` and fail by test order.
    @Test func aRevealTestLeavesTheAnimationSpeedAsItFoundIt() {
        let saved = DesignSettings.shared.animationSpeed
        defer { DesignSettings.shared.animationSpeed = saved }
        DesignSettings.shared.animationSpeed = .fast
        thePlusIsHiddenUntilThePointerIsOverTheStrip()
        #expect(DesignSettings.shared.animationSpeed == .fast)
    }

    @Test func thePlusIsHiddenUntilThePointerIsOverTheStrip() {
        withHarness { h in
            #expect(!h.plusVisible)
            h.enter()
            #expect(h.plusVisible)
            h.exit()
            #expect(!h.plusVisible)
        }
    }

    @Test func movingOverTheStripRevealsThemWithoutAnEnterEvent() {
        withHarness { h in
            h.move(to: CGPoint(x: 100, y: 10))
            #expect(h.plusVisible)
        }
    }

    @Test func revealingThePlusNeverMovesTheTabs() {
        withHarness { h in
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
    }

    @Test func anOpenStripMenuKeepsThemUntilItCloses() throws {
        try withHarness { h in
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
            #expect(h.plusVisible, "the pointer left for the menu; the plus stays")
            NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: shown)
            #expect(!h.plusVisible)
        }
    }

    /// R120: the plus button shows only while the tab bar is hovered, in
    /// place, through the one hover-reveal mechanism (HoverReveal).
    @Test func thePlusButtonRevealsOnlyOnHover() {
        withHarness { h in
            let frame = h.strip.newTabButton.frame
            #expect(!h.strip.newTabButton.isHidden)
            #expect(!h.plusVisible)
            h.enter()
            #expect(h.plusVisible)
            #expect(h.strip.newTabButton.frame == frame)
            h.exit()
            #expect(!h.plusVisible)
            #expect(HoverReveal.owner(of: h.strip.newTabButton) === h.strip.reveal.hover)
        }
    }

    /// TAB-STRIP-TRAILING-BUTTONS-REMOVED follow-up: the plus is a hover
    /// reveal, so a VoiceOver user never hovers it. It shows while VoiceOver
    /// focuses the strip, one of its tabs, or the plus itself.
    @Test func voiceOverFocusInTheStripRevealsThePlus() throws {
        try withHarness { h in
            #expect(!h.plusVisible)
            h.strip.setAccessibilityFocused(true)
            #expect(h.plusVisible, "VoiceOver on the strip")
            h.strip.setAccessibilityFocused(false)
            #expect(!h.plusVisible)

            let tab = try #require(h.strip.accessibilityChildren()?.first as? NSAccessibilityElement)
            tab.setAccessibilityFocused(true)
            #expect(h.plusVisible, "VoiceOver on a tab")
            // Focus moves from the tab to the plus: it stays shown throughout.
            h.strip.newTabButton.setAccessibilityFocused(true)
            tab.setAccessibilityFocused(false)
            #expect(h.plusVisible, "VoiceOver on the plus")
            h.strip.newTabButton.setAccessibilityFocused(false)
            #expect(!h.plusVisible, "VoiceOver left the strip")
        }
    }

    /// `tabs.plusButton` = always keeps the plus shown at rest; back to
    /// hover hides it again.
    @Test func plusButtonAlwaysKeepsThePlusShown() {
        let saved = DesignSettings.shared.plusButton
        defer { DesignSettings.shared.plusButton = saved }
        DesignSettings.shared.plusButton = .always
        withHarness { h in
            #expect(h.plusVisible)
            DesignSettings.shared.plusButton = .hover
            h.strip.reveal.applyPlusButtonMode()
            #expect(!h.plusVisible)
        }
    }
}
