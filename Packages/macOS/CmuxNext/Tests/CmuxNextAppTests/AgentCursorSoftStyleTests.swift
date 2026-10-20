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

    @Test func theNameTagIsLightGlassWithDarkText() throws {
        let cursor = try placed()
        let tag = try #require(gray(cursor.nameTag.backgroundColor))
        let text = try #require(gray(cursor.nameText.foregroundColor))
        #expect(tag.level > 0.9, "light material, not the pointer fill")
        #expect(text.level < 0.25, "dark text on the light tag")
        #expect(cursor.nameTag.cornerRadius * 2 >= cursor.nameTag.bounds.height - 0.5, "a pill")
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
