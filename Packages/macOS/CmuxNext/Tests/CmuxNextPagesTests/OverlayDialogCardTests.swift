import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextPages
import Testing

/// Lawrence 2026-11-07, a Leave site? dialog over Gmail: "dialog has weird roundness", "like there's weird
/// border??". The card sits in the overlay panel, a clear window over the page's own window. Liquid Glass
/// there has nothing in its window to bend, and its lens drew a dark 1 px outline under the rim; the card
/// also cast no shadow, so it read flat on the page. Every dialog (JavaScript alert, confirm, prompt, Leave
/// site?, HTTP sign-in) draws on this one card.
@MainActor
struct OverlayDialogCardTests {
    @Test func theCardBlursWhatIsBehindItsClearWindowNeverLiquidGlass() {
        let card = OverlayDialogCard(activeLook: nil)
        #expect(card.glass.prefersBlurToLiquidGlass)
        #expect(card.glass.samplesBehindWindow)
        #expect(card.glass.material != .liquidGlass)
    }

    @Test func theCardCastsThePopupShadowAtItsOwnRoundedRect() throws {
        let card = OverlayDialogCard(activeLook: nil)
        card.frame = NSRect(x: 40, y: 30, width: 380, height: 150)
        card.layoutSubtreeIfNeeded()
        let shadow = try #require(card.shadowLayer)
        let elevation = PopupStyle.standard.elevation
        #expect(shadow.shadowOpacity == Float(elevation.alpha))
        #expect(shadow.shadowRadius == elevation.layerRadius)
        #expect(shadow.shadowOffset == elevation.layerOffset())
        // The shadow follows the card's rect and corner, and the cutout keeps it off the glass.
        // One radius: the shadow's corner is the glass's.
        let radius = card.glass.cornerRadius
        #expect(shadow.shadowPath == CGPath(roundedRect: card.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
        #expect(card.glass.frame == card.bounds)
        let cutout = try #require(shadow.mask as? CAShapeLayer)
        #expect(cutout.fillRule == .evenOdd)
        #expect(cutout.path?.contains(CGPoint(x: card.bounds.midX, y: card.bounds.midY), using: .evenOdd) == false)
        #expect(cutout.path?.contains(CGPoint(x: card.bounds.midX, y: -elevation.offset), using: .evenOdd) == true)
    }
}
