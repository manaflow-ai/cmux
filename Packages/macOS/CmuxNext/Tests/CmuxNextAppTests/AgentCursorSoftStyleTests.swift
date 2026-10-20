@testable import CmuxNextAgentCursor
import Foundation
import QuartzCore
import Testing

/// Cursor gallery pick T1 (user, 2026-10-20: "I like the minimal triangle. It
/// just needs to be more friendly", rounder and glassy, and "the cursor color
/// for all the browser view stuff needs to be gray"): a rounded gray triangle
/// with a white rim, and a light glass pill tag with dark text at its tip.
@MainActor
struct AgentCursorSoftStyleTests {
    final class Visible: AgentCursorTargetResolving {
        func placement(forTarget targetID: String) -> AgentCursorPlacement {
            .visible(content: CGRect(x: 0, y: 0, width: 800, height: 600), clip: CGRect(x: 0, y: 0, width: 800, height: 600),
                     zoom: 1, magnification: 1)
        }
    }

    private func placed(_ session: String = "cmux-browser-cli:Claude") throws -> AgentCursorLayer {
        let stack = AgentCursorStack(hostLayer: CALayer(), resolver: Visible())
        stack.host.apply(.place(session: session, point: CGPoint(x: 100, y: 100)))
        return try #require(stack.host.cursorLayer(for: session))
    }

    private func gray(_ color: CGColor?) -> (level: CGFloat, chroma: CGFloat)? {
        guard let rgb = color?.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let c = rgb.components, c.count >= 3 else { return nil }
        return ((c[0] + c[1] + c[2]) / 3, max(c[0], c[1], c[2]) - min(c[0], c[1], c[2]))
    }

    @Test(arguments: ["cmux-browser-cli:Claude", "cmux-browser-cli:Codex", "chief-a139", "repl-7"])
    func everyAgentsPointerIsGray(session: String) throws {
        let cursor = try placed(session)
        let fill = try #require(gray(cursor.arrow.fillColor))
        #expect(fill.chroma < 0.02, "gray, not a per-session palette color")
        #expect(fill.level > 0.4 && fill.level < 0.75, "a mid gray that reads on light and dark pages")
    }

    @Test func thePointerTipIsRounded() {
        // A sharp tip covers the spot just inside its corner; a rounded tip leaves it empty.
        #expect(!AgentCursorLayer.arrowPath.contains(CGPoint(x: 0.15, y: 0.15)))
        let box = AgentCursorLayer.arrowPath.boundingBoxOfPath
        #expect(abs(box.minX) < 0.75 && abs(box.minY) < 0.75, "the hotspot stays at the tip")
    }

    @Test func thePointerHasAWhiteRim() throws {
        let cursor = try placed()
        let rim = try #require(gray(cursor.arrow.strokeColor))
        #expect(rim.level > 0.95 && cursor.arrow.lineWidth >= 1.2)
    }

    /// Pill gallery P1 (user, 2026-10-20: "gray and liquid glassy, think
    /// about how Apple would design this"): a neutral gray, translucent
    /// capsule with continuous corners, a specular top and a light rim, a
    /// soft shadow and dark label text; no agent color anywhere in it.
    @Test func theNameTagIsGrayLiquidGlass() throws {
        let cursor = try placed()
        let fill = try #require(cursor.nameTag.backgroundColor)
        let tint = try #require(gray(fill))
        #expect(tint.chroma < 0.02, "neutral gray, never an agent color")
        #expect(tint.level > 0.6 && tint.level < 0.9, "a gray tint, not the old near-white")
        #expect(fill.alpha > 0.55 && fill.alpha < 0.9, "translucent: the page shows through")
        #expect(cursor.nameTag.cornerCurve == .continuous, "a continuous-corner capsule")
        #expect(cursor.nameTag.cornerRadius * 2 >= cursor.nameTag.bounds.height - 0.5, "a capsule")
        let rim = try #require(gray(cursor.nameTag.borderColor))
        #expect(rim.level > 0.95 && (cursor.nameTag.borderColor?.alpha ?? 0) > 0.3, "a light specular rim, not a dark hairline")
        let sheen = try #require(cursor.nameTag.sublayers?.compactMap { $0 as? CAGradientLayer }.first, "a specular highlight")
        #expect(sheen.frame.minY <= 0.5 && sheen.frame.height <= cursor.nameTag.bounds.height * 0.7, "the highlight sits on the top edge")
        #expect(cursor.nameTag.shadowOpacity > 0.05 && cursor.nameTag.shadowOpacity < 0.3, "a subtle shadow")
        let text = try #require(gray(cursor.nameText.foregroundColor))
        #expect(text.level < 0.3, "dark label text")
        let dot = try #require(gray(cursor.nameDot.fillColor))
        #expect(dot.chroma < 0.02, "the dot is gray too")
        #expect(cursor.nameTag.frame.minX < 16 && cursor.nameTag.frame.minY < 18, "tucked against the tip")
    }

    @Test func thePausedOutlineStaysVisible() throws {
        let cursor = try placed()
        cursor.isPaused = true
        #expect(cursor.arrow.fillColor == nil)
        let outline = try #require(gray(cursor.arrow.strokeColor))
        #expect(outline.level < 0.8, "a white rim alone would vanish on a white page")
    }
}
