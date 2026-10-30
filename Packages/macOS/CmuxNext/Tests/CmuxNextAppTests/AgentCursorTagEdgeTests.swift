import CmuxAgentCursor
@testable import CmuxNextAgentCursor
import Foundation
import QuartzCore
import Testing

/// Browser use (user, 2026-10-21: "for browser use cursor we need to place the
/// tooltip such that it doesnt overflow out the page"): the agent cursor's name
/// tag and keystroke caption stay inside the visible page at every edge and
/// corner, at any zoom, and do not flip back and forth along an edge.
@MainActor
struct AgentCursorTagEdgeTests {
    /// A page whose viewport sits at (100, 50), 800 × 600 overlay points.
    final class Page: AgentCursorTargetResolving {
        static let clip = CGRect(x: 100, y: 50, width: 800, height: 600)
        let zoom: Double
        init(zoom: Double) { self.zoom = zoom }
        func placement(forTarget targetID: String) -> AgentCursorPlacement {
            .visible(content: Self.clip, clip: Self.clip, zoom: zoom, magnification: 1)
        }
    }

    /// A long tag, as in the report ("Claude · Chief AWS…").
    static let name = "Claude · Chief AWS profile sign-in"

    /// Edges and corners of the page, as fractions of its size (0 and 1 are the edges themselves).
    static let spots: [(Double, Double)] = [
        (0.5, 0.5), (1, 0.5), (0, 0.5), (0.5, 0), (0.5, 1),
        (0, 0), (1, 0), (0, 1), (1, 1), (0.98, 0.98), (0.97, 0.3), (0.3, 0.97),
    ]

    private func stage(zoom: Double) -> (AgentCursorOverlayModel, AgentCursorLayerHost) {
        let host = AgentCursorLayerHost(hostLayer: CALayer(), color: { _ in CGColor(gray: 1, alpha: 1) },
                                        label: { _ in Self.name })
        let model = AgentCursorOverlayModel(resolver: Page(zoom: zoom), host: host, animatesMovement: { false })
        return (model, host)
    }

    private func click(_ model: AgentCursorOverlayModel, fx: Double, fy: Double, zoom: Double, seq: Int) {
        // Page CSS px: the overlay size divided by the zoom.
        let x = fx * Page.clip.width / zoom, y = fy * Page.clip.height / zoom
        model.render(AutomationInputEvent(sessionID: "s", targetID: "T", seq: UInt64(seq), kind: .click, space: .viewport,
                                          point: .init(x: x, y: y), tMs: Double(seq) * 1000))
    }

    @Test(arguments: [1.0, 0.5, 2.0])
    func theTagAndCaptionStayInsideThePageAtEveryEdgeAndCorner(zoom: Double) throws {
        let (model, host) = stage(zoom: zoom)
        for (index, spot) in Self.spots.enumerated() {
            click(model, fx: spot.0, fy: spot.1, zoom: zoom, seq: index)
            host.apply(.caption(session: "s", text: "typing a fairly long line of text"))
            let tag = try #require(host.tagSpots().first?.frame)
            #expect(Page.clip.contains(tag), "tag \(tag) leaves the page at \(spot), zoom \(zoom)")
            let cursor = try #require(host.cursorLayer(for: "s"))
            let caption = cursor.caption.frame.offsetBy(dx: cursor.root.position.x, dy: cursor.root.position.y)
            #expect(Page.clip.contains(caption), "caption \(caption) leaves the page at \(spot), zoom \(zoom)")
            #expect(!tag.intersects(caption), "the caption never covers the tag at \(spot)")
        }
    }

    @Test func theTagRestsBelowRightAwayFromTheEdges() throws {
        let (model, host) = stage(zoom: 1)
        click(model, fx: 0.3, fy: 0.3, zoom: 1, seq: 0)
        let tip = try #require(host.cursorLayer(for: "s")).root.position
        let tag = try #require(host.tagSpots().first?.frame)
        #expect(tag.minX > tip.x && tag.minY > tip.y, "below-right of the tip, off the point acted on")
    }

    @Test func nearTheRightEdgeTheTagFlipsLeftAndStaysThereWhileTheCursorWobbles() throws {
        let (model, host) = stage(zoom: 1)
        click(model, fx: 0.99, fy: 0.3, zoom: 1, seq: 0)
        func tagIsLeftOfTip() throws -> Bool {
            let tip = try #require(host.cursorLayer(for: "s")).root.position
            return try #require(host.tagSpots().first?.frame).maxX <= tip.x
        }
        #expect(try tagIsLeftOfTip(), "flipped left of the tip at the right edge")
        // A few points back from the edge: not enough room yet; the tag stays put.
        let tagWidth = try #require(host.tagSpots().first?.frame.width)
        // The tip where a below-right tag would just fit (a 4 pt edge margin, the tag 7 pt right of the tip).
        let justFits = (Page.clip.width - 4 - 7 - tagWidth) / Page.clip.width
        click(model, fx: justFits - 2 / Page.clip.width, fy: 0.3, zoom: 1, seq: 1)
        #expect(try tagIsLeftOfTip(), "no flip back without room to spare")
        click(model, fx: 0.99, fy: 0.3, zoom: 1, seq: 2)
        #expect(try tagIsLeftOfTip())
        click(model, fx: 0.2, fy: 0.3, zoom: 1, seq: 3)
        #expect(try !tagIsLeftOfTip(), "back to the right with room to spare")
    }

    @Test func nearTheBottomEdgeTheTagFlipsAbove() throws {
        let (model, host) = stage(zoom: 1)
        click(model, fx: 0.3, fy: 1, zoom: 1, seq: 0)
        let tip = try #require(host.cursorLayer(for: "s")).root.position
        let tag = try #require(host.tagSpots().first?.frame)
        #expect(tag.maxY <= tip.y, "above the tip at the bottom edge")
    }

    @Test func aPageResizeMovesTheTagBackInside() throws {
        final class Shrinking: AgentCursorTargetResolving {
            var clip = CGRect(x: 0, y: 0, width: 800, height: 600)
            func placement(forTarget targetID: String) -> AgentCursorPlacement {
                .visible(content: CGRect(x: 0, y: 0, width: 800, height: 600), clip: clip, zoom: 1, magnification: 1)
            }
        }
        let resolver = Shrinking()
        let host = AgentCursorLayerHost(hostLayer: CALayer(), color: { _ in CGColor(gray: 1, alpha: 1) },
                                        label: { _ in Self.name })
        let model = AgentCursorOverlayModel(resolver: resolver, host: host, animatesMovement: { false })
        model.render(AutomationInputEvent(sessionID: "s", targetID: "T", seq: 0, kind: .click, space: .viewport,
                                          point: .init(x: 300, y: 300), tMs: 0))
        resolver.clip = CGRect(x: 0, y: 0, width: 360, height: 600)
        model.placementsDidChange(target: "T")
        let tag = try #require(host.tagSpots().first?.frame)
        #expect(resolver.clip.contains(tag), "tag \(tag) left the narrowed page")
    }
}
