import AppKit
@testable import CmuxNextTabs
import Testing

@MainActor @Suite(.serialized) struct NewTabMenuTriggerTests {
    @Test func accessibilityMenuKeepsThePlusLitUntilTrackingEnds() throws {
        let strip = TabStripView(model: TabStripModel(tabs: [], selectedID: nil))
        strip.opensNewTabMenuOnPress = true
        let button = strip.newTabButton
        button.isHovered = false
        button.isPressed = false
        button.updateLayer()
        let glyph = try #require(button.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first)
        let restingWidth = glyph.lineWidth
        let restingInk = glyph.strokeColor
        let menu = NSMenu()
        menu.addItem(withTitle: "Terminal", action: nil, keyEquivalent: "")
        strip.contextMenuProvider = { _ in menu }
        var presentations = 0
        strip.presentNewTabMenu = { _, _, _ in
            presentations += 1
            #expect(glyph.lineWidth > restingWidth)
            #expect(button.layer?.sublayers?.first?.backgroundColor == nil, "menu state preserves the plain glyph")
            // A hover transition during tracking must not clear the held glyph state.
            button.isHovered = true
            button.isHovered = false
            #expect(glyph.lineWidth > restingWidth)
            #expect(button.layer?.sublayers?.first?.backgroundColor == nil, "menu state preserves the plain glyph")
        }
        #expect(button.accessibilityPerformShowMenu())
        #expect(presentations == 1)
        #expect(glyph.lineWidth == restingWidth)
        #expect(glyph.strokeColor == restingInk)
        #expect(button.layer?.sublayers?.first?.backgroundColor == nil)
    }

    @Test func unrelatedTabMenuDoesNotLightThePlus() throws {
        let strip = TabStripView(model: TabStripModel(tabs: [], selectedID: nil))
        let button = strip.newTabButton
        button.updateLayer()
        let glyph = try #require(button.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first)
        let restingWidth = glyph.lineWidth
        let restingInk = glyph.strokeColor
        strip.menuTracking.begin(NSMenu())
        #expect(glyph.lineWidth == restingWidth)
        #expect(glyph.strokeColor == restingInk)
        #expect(button.layer?.sublayers?.first?.backgroundColor == nil)
        strip.menuTracking.end()
    }
}
