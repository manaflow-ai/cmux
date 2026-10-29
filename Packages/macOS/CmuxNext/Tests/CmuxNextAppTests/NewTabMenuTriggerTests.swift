import AppKit
@testable import CmuxNextTabs
import Testing

@MainActor @Suite(.serialized) struct NewTabMenuTriggerTests {
    @Test func accessibilityMenuKeepsThePlusLitUntilTrackingEnds() {
        let strip = TabStripView(model: TabStripModel(tabs: [], selectedID: nil))
        strip.opensNewTabMenuOnPress = true
        let button = strip.newTabButton
        button.isHovered = false
        button.isPressed = false
        button.updateLayer()
        let restingFill = button.layer?.sublayers?.first?.backgroundColor
        let menu = NSMenu()
        menu.addItem(withTitle: "Terminal", action: nil, keyEquivalent: "")
        strip.contextMenuProvider = { _ in menu }
        var presentations = 0
        strip.presentNewTabMenu = { _, _, _ in
            presentations += 1
            #expect(button.layer?.sublayers?.first?.backgroundColor != restingFill)
            // A hover transition during tracking must not clear the active menu fill.
            button.isHovered = true
            button.isHovered = false
            #expect(button.layer?.sublayers?.first?.backgroundColor != restingFill)
        }
        #expect(button.accessibilityPerformShowMenu())
        #expect(presentations == 1)
        #expect(button.layer?.sublayers?.first?.backgroundColor == restingFill)
    }

    @Test func unrelatedTabMenuDoesNotLightThePlus() {
        let strip = TabStripView(model: TabStripModel(tabs: [], selectedID: nil))
        let button = strip.newTabButton
        button.updateLayer()
        let restingFill = button.layer?.sublayers?.first?.backgroundColor
        strip.menuTracking.begin(NSMenu())
        #expect(button.layer?.sublayers?.first?.backgroundColor == restingFill)
        strip.menuTracking.end()
    }
}
