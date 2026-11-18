import AppKit
@testable import CmuxNextTabs
import Testing

/// The + stays lit while its own menu is open. Since #42825 (Lucas 2026-11-14, "keep new tab glyph weight constant") the
/// stroke keeps one weight in every state, so "lit" is the pressed ink (`NewTabButtonView.glyphInk`), never a heavier
/// stroke and never a plate behind the glyph.
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
            #expect(glyph.strokeColor != restingInk, "the + is lit while its menu is open")
            #expect(glyph.lineWidth == restingWidth, "the stroke keeps its weight")
            #expect(button.layer?.sublayers?.first?.backgroundColor == nil, "menu state preserves the plain glyph")
            let litInk = glyph.strokeColor
            // A hover transition during tracking must not clear the held glyph state.
            button.isHovered = true
            button.isHovered = false
            #expect(glyph.strokeColor == litInk, "a hover during tracking keeps the + lit")
            #expect(glyph.lineWidth == restingWidth)
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
