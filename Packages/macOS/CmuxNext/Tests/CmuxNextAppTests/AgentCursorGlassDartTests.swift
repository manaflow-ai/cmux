import CmuxAgentCursor
@testable import CmuxNextAgentCursor
import CmuxNextDesign
import Foundation
import QuartzCore
import Testing

/// User, 2026-10-20: make the cursor glassier but clearly visible on every
/// surface (light, dark, busy photos, white pages, terminals), with a real
/// blur and a contrast rim, and make it quick: short motion through the
/// Motion gate, instant under Reduce Motion.
@MainActor
@Suite(.serialized)
struct AgentCursorGlassDartTests {
    final class Visible: AgentCursorTargetResolving {
        func placement(forTarget targetID: String) -> AgentCursorPlacement {
            .visible(content: CGRect(x: 0, y: 0, width: 800, height: 600), clip: CGRect(x: 0, y: 0, width: 800, height: 600),
                     zoom: 1, magnification: 1)
        }
    }

    private func placed() throws -> (AgentCursorStack, AgentCursorLayer) {
        let stack = AgentCursorStack(hostLayer: CALayer(), glassLayer: CALayer(), resolver: Visible())
        stack.host.apply(.place(session: "s", point: CGPoint(x: 100, y: 100)))
        return (stack, try #require(stack.host.cursorLayer(for: "s")))
    }

    private func components(_ color: CGColor?) -> (level: CGFloat, alpha: CGFloat)? {
        guard let rgb = color?.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let c = rgb.components, c.count >= 4 else { return nil }
        return ((c[0] + c[1] + c[2]) / 3, c[3])
    }

    @Test func theDartSitsOnARealBlurOfThePage() throws {
        let (_, cursor) = try placed()
        #expect(cursor.glassArrow.superlayer?.superlayer === cursor.glassRoot, "a blur well in the window's glass mask")
        #expect(cursor.glassArrow.path == AgentCursorLayer.arrowPath, "the dart's own shape")
        #expect(components(cursor.glassArrow.fillColor)?.alpha == 1, "an opaque well: the full blur shows")
        let fill = try #require(components(cursor.arrow.fillColor))
        #expect(fill.alpha > 0.35 && fill.alpha < 0.75, "a gray tint the blur shows through")
    }

    @Test func aDarkHairlineAndAWhiteRimKeepTheDartOnEverySurface() throws {
        let (_, cursor) = try placed()
        let rim = try #require(components(cursor.arrow.strokeColor))
        #expect(rim.level > 0.95, "white rim: reads on dark pages and terminals")
        let outline = try #require(components(cursor.arrowOutline.strokeColor))
        #expect(outline.level < 0.1 && outline.alpha >= 0.3, "dark hairline: reads on white pages")
        #expect(cursor.arrowOutline.lineWidth > cursor.arrow.lineWidth, "the dark line shows outside the white one")
        #expect(cursor.arrowOutline.shadowOpacity > 0, "a soft shadow lifts it off busy photos")
    }

    @Test func theBlurTurnsWithTheDart() throws {
        let (stack, cursor) = try placed()
        let plan = GlideMotion().plan(fromX: 100, fromY: 100, toX: 400, toY: 300, endHeading: 2.5)
        stack.host.apply(.glide(session: "s", plan: plan))
        let arrow = (cursor.heading.value(forKeyPath: "transform.rotation.z") as? Double) ?? 0
        let well = (cursor.glassHeading.value(forKeyPath: "transform.rotation.z") as? Double) ?? 0
        #expect(abs(arrow - well) < 1e-9)
        #expect(cursor.glassRoot.position == cursor.root.position)
    }

    @Test func aGlideIsShortAndGoesThroughTheMotionGate() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let natural = 1.1
        let snappy = try #require(Motion.cursor.agentCursorGlideDuration(natural), "movement animates")
        #expect(snappy < natural / 1.5, "much quicker than the cmux-cua glide")
        #expect(snappy <= MotionTunables.agentCursorGlideMax.value * max(Motion.speed.timeScale, 1) + 1e-9)
        let (stack, cursor) = try placed()
        let plan = GlideMotion().plan(fromX: 100, fromY: 100, toX: 700, toY: 500, endHeading: 2.5)
        #expect(plan.duration > 0.5)
        stack.host.apply(.glide(session: "s", plan: plan))
        let played = try #require(cursor.lastGlideDuration)
        #expect(played > 0 && played <= snappy + 1e-9 && played < plan.duration / 1.5)
    }

    @Test func reduceMotionMovesTheCursorAtOnce() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        #expect(Motion.cursor.agentCursorGlideDuration(1.1) == nil)
        let (stack, cursor) = try placed()
        let plan = GlideMotion().plan(fromX: 100, fromY: 100, toX: 700, toY: 500, endHeading: 2.5)
        stack.host.apply(.glide(session: "s", plan: plan))
        #expect(cursor.lastGlideDuration == 0)
        #expect(cursor.root.animation(forKey: "agentCursor.glide") == nil)
        let end = try #require(plan.samples.last)
        #expect(cursor.root.position == CGPoint(x: end.x, y: end.y))
        #expect(cursor.glassRoot.position == cursor.root.position)
    }
}
