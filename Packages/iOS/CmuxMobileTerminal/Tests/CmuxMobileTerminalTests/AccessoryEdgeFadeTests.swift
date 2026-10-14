import CoreGraphics
import Testing
import UIKit

@testable import CmuxMobileTerminal

@Suite("Accessory leading-edge scroll fade")
struct AccessoryEdgeFadeTests {
    @Test("edge stays fully opaque at rest and during leading bounce")
    func opaqueAtRest() {
        #expect(AccessoryEdgeFadeScrollView.leadingEdgeAlpha(contentOffsetX: 0) == 1)
        // Rest position when the host carries the 4pt inter-button gap as a
        // leading content inset: still no fade until a key reaches the edge.
        #expect(AccessoryEdgeFadeScrollView.leadingEdgeAlpha(contentOffsetX: -4) == 1)
        #expect(AccessoryEdgeFadeScrollView.leadingEdgeAlpha(contentOffsetX: -30) == 1)
    }

    @Test("fade ramps linearly with the first points of scroll")
    func incrementalRamp() {
        let quarter = AccessoryEdgeFadeScrollView.leadingEdgeAlpha(contentOffsetX: 6, fadeWidth: 24)
        let half = AccessoryEdgeFadeScrollView.leadingEdgeAlpha(contentOffsetX: 12, fadeWidth: 24)
        #expect(abs(quarter - 0.75) < 0.0001)
        #expect(abs(half - 0.5) < 0.0001)
    }

    @Test("fade saturates once scrolled a full band width")
    func saturates() {
        #expect(AccessoryEdgeFadeScrollView.leadingEdgeAlpha(contentOffsetX: 24, fadeWidth: 24) == 0)
        #expect(AccessoryEdgeFadeScrollView.leadingEdgeAlpha(contentOffsetX: 500, fadeWidth: 24) == 0)
    }

    @Test("band fraction spans the band, clamped to degenerate viewports")
    func bandFraction() {
        #expect(abs(AccessoryEdgeFadeScrollView.fadeBandFraction(viewportWidth: 240, fadeWidth: 24) - 0.1) < 0.0001)
        #expect(AccessoryEdgeFadeScrollView.fadeBandFraction(viewportWidth: 10, fadeWidth: 24) == 1)
        #expect(AccessoryEdgeFadeScrollView.fadeBandFraction(viewportWidth: 0, fadeWidth: 24) == 0)
    }

    @Test("held glass gets vertical mask overscan")
    func heldGlassMaskOverscan() {
        let rowBounds = CGRect(x: 0, y: 0, width: 240, height: 28)
        let maskBounds = AccessoryEdgeFadeScrollView.maskBounds(for: rowBounds)

        #expect(maskBounds.minX == rowBounds.minX)
        #expect(maskBounds.maxX == rowBounds.maxX)
        #expect(maskBounds.minY < rowBounds.minY)
        #expect(maskBounds.maxY > rowBounds.maxY)
        #expect(maskBounds.midY == rowBounds.midY)
    }

    @MainActor
    @Test("shortcut row keeps native horizontal scroll physics")
    func shortcutRowKeepsNativeScrollPhysics() throws {
        let input = TerminalInputTextView()
        let scrollView = try #require(Self.findAccessoryScrollView(in: input.toolbarView))

        #expect(scrollView.bounces)
        #expect(scrollView.alwaysBounceHorizontal)
        #expect(scrollView.decelerationRate == .normal)
    }

    @MainActor
    @Test("shortcut row defers layout correction during an active gesture")
    func defersOffsetCorrectionDuringGesture() {
        let input = TerminalInputTextView()
        let decision = input.accessoryOffsetDecision(
            geometryChanged: true,
            interactionActive: true,
            previousOffset: 100,
            currentOffset: 130,
            minimumOffset: 0,
            maximumOffset: 120,
            wasAtLeadingEdge: false,
            wasAtTrailingEdge: true
        )

        #expect(decision == .deferUntilScrollEnds)
    }

    @MainActor
    @Test("shortcut row clamps stale overscroll after the gesture ends")
    func clampsStaleOverscrollAfterGesture() {
        let input = TerminalInputTextView()
        let decision = input.accessoryOffsetDecision(
            geometryChanged: true,
            interactionActive: false,
            previousOffset: 100,
            currentOffset: 130,
            minimumOffset: 0,
            maximumOffset: 120,
            wasAtLeadingEdge: false,
            wasAtTrailingEdge: true,
            preserveEdge: false
        )

        #expect(decision == .set(120))
    }

    @MainActor
    @Test("shortcut row keeps the trailing edge through a resting resize")
    func keepsTrailingEdgeThroughResize() {
        let input = TerminalInputTextView()
        let decision = input.accessoryOffsetDecision(
            geometryChanged: true,
            interactionActive: false,
            previousOffset: 100,
            currentOffset: 100,
            minimumOffset: 0,
            maximumOffset: 120,
            wasAtLeadingEdge: false,
            wasAtTrailingEdge: true
        )

        #expect(decision == .set(120))
    }

    @MainActor
    private static func findAccessoryScrollView(in view: UIView) -> AccessoryEdgeFadeScrollView? {
        if let scrollView = view as? AccessoryEdgeFadeScrollView {
            return scrollView
        }
        for subview in view.subviews {
            if let scrollView = findAccessoryScrollView(in: subview) {
                return scrollView
            }
        }
        return nil
    }
}
