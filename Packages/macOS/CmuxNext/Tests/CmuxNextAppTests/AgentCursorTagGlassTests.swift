import CmuxAgentCursor
@testable import CmuxNextAgentCursor
import CmuxNextDesign
import Foundation
import QuartzCore
import Testing

/// The cursor's "Chief · workspace" tag and keystroke caption use the one shared Liquid Glass
/// style (``FloatingGlassStyle/agentTag``: the toast's neutral veil and soft top-lit rim, a
/// capsule), not a look of their own, and draw opaque under Reduce Transparency like every
/// other glass surface (Chief via a286, 2026-10-20).
@MainActor
struct AgentCursorTagGlassTests {
    final class Visible: AgentCursorTargetResolving {
        func placement(forTarget targetID: String) -> AgentCursorPlacement {
            .visible(content: CGRect(x: 0, y: 0, width: 800, height: 600), clip: CGRect(x: 0, y: 0, width: 800, height: 600),
                     zoom: 1, magnification: 1)
        }
    }

    private let session = "cmux-browser-cli:Claude"

    private func placed(reduced: Bool = false) throws -> AgentCursorLayer {
        let stack = AgentCursorStack(hostLayer: CALayer(), resolver: Visible(),
                                     reduceTransparency: ReduceTransparency(system: { reduced }, changes: NotificationCenter()))
        stack.host.apply(.place(session: session, point: CGPoint(x: 100, y: 100)))
        let cursor = try #require(stack.host.cursorLayer(for: session))
        cursor.showCaption("hello", scale: 2)
        return cursor
    }

    private func srgb(_ color: CGColor?) -> [CGFloat]? {
        color?.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components
    }

    private func matches(_ color: CGColor?, _ gray: FloatingGlassLook.Gray) -> Bool {
        guard let c = srgb(color), c.count == 4 else { return false }
        return c[0...2].allSatisfy { abs($0 - gray.white) < 0.01 } && abs(c[3] - gray.alpha) < 0.01
    }

    /// The rim: a gradient masked to a stroke around the pill, top to bottom.
    private func rimLayer(of pill: CALayer) -> CAGradientLayer? {
        pill.sublayers?.compactMap { $0 as? CAGradientLayer }.first {
            guard let stroke = $0.mask as? CAShapeLayer else { return false }
            return stroke.fillColor == nil && stroke.lineWidth > 0 && stroke.path != nil
        }
    }

    @Test func theTagAndCaptionWearTheSharedGlass() throws {
        let cursor = try placed()
        let look = FloatingGlassStyle.agentTag.look(isDark: false)
        for pill in [cursor.nameTag, cursor.caption] {
            #expect(matches(pill.backgroundColor, look.veil), "the shared neutral veil")
            #expect(pill.borderWidth == 0, "the shared rim, not a flat border")
            let rim = try #require(rimLayer(of: pill), "the shared soft top-lit rim")
            let colors = try #require(rim.colors as? [CGColor])
            #expect(colors.count == 2 && matches(colors[0], look.rimTop) && matches(colors[1], look.rimBottom))
            #expect(rim.frame == pill.bounds)
            #expect(pill.cornerCurve == .continuous)
        }
        #expect(cursor.nameTag.cornerRadius == FloatingGlassStyle.agentTag.cornerRadius)
        #expect(cursor.nameTag.bounds.height == FloatingGlassStyle.agentTag.cornerRadius * 2, "a capsule")
    }

    @Test func reduceTransparencyDrawsTheTagOpaque() throws {
        let cursor = try placed(reduced: true)
        for pill in [cursor.nameTag, cursor.caption] {
            let fill = try #require(srgb(pill.backgroundColor))
            #expect(fill[3] == 1, "opaque, no glass")
            #expect(abs(fill[0] - fill[1]) < 0.01 && abs(fill[1] - fill[2]) < 0.01, "still neutral gray")
            #expect(rimLayer(of: pill)?.isHidden ?? true, "no rim on the opaque surface, like the shared toast")
        }
    }

    @Test func theHoverStaysInTheSharedGlass() throws {
        let cursor = try placed()
        let resting = try #require(srgb(cursor.nameTag.backgroundColor))
        cursor.isTagHighlighted = true
        let hovered = try #require(srgb(cursor.nameTag.backgroundColor))
        #expect(hovered[3] > resting[3], "a denser veil says it is a link")
        #expect(abs(hovered[0] - hovered[1]) < 0.01 && abs(hovered[1] - hovered[2]) < 0.01, "neutral gray")
        cursor.isTagHighlighted = false
        #expect(srgb(cursor.nameTag.backgroundColor) == resting)
    }
}
