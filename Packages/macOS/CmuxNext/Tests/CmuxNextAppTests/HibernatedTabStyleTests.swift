import AppKit
import CmuxNextDesign
@testable import CmuxNextTabs
import QuartzCore
import Testing

/// A hibernated tab looks as Chrome draws a discarded (Memory Saver) tab
/// (`chrome/browser/ui/views/tabs/tab/tab_icon.cc`): the favicon shrinks to 14 of
/// 16 points inside a circle, a dotted ring surrounds it, and nothing is dimmed.
@MainActor @Suite(.serialized) struct HibernatedTabStyleTests {
    private func item(dormant: Bool) -> TabItem {
        var item = TabItem(id: TabID("page"), title: "Example")
        item.isDormant = dormant
        return item
    }

    @Test func aHibernatedTabShowsTheRingAndAShrunkenCircularIcon() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let cell = TabCell(item: item(dormant: true))
        cell.frame = CGRect(x: 0, y: 0, width: 200, height: 32)
        let ring = try #require(cell.hibernationRingLayer, "a hibernated tab has no ring")
        #expect(ring.superlayer === cell.layer)
        #expect(ring.path != nil && ring.isHidden == false)
        #expect(ring.lineWidth == 1.5)
        #expect(abs(cell.iconLayer.transform.m11 - 14.0 / 16.0) < 0.0001, "the favicon is not shrunk to Chrome's 14 of 16 points")
        #expect(cell.iconLayer.masksToBounds && cell.iconLayer.cornerRadius == cell.iconLayer.bounds.width / 2,
                "the favicon is not clipped to a circle")
        // Chrome neither dims the favicon nor recolors the title of a discarded tab.
        #expect(cell.iconLayer.opacity == 1)
        let ringBox = ring.frame
        let iconBox = CGRect(x: cell.iconLayer.position.x - cell.iconLayer.bounds.width / 2,
                             y: cell.iconLayer.position.y - cell.iconLayer.bounds.height / 2,
                             width: cell.iconLayer.bounds.width, height: cell.iconLayer.bounds.height)
        #expect(ringBox == iconBox.insetBy(dx: -2, dy: -2), "the ring is not two points outside the icon")
    }

    @Test func wakingRemovesTheRingAndRestoresTheIcon() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let cell = TabCell(item: item(dormant: false))
        cell.frame = CGRect(x: 0, y: 0, width: 200, height: 32)
        #expect(cell.hibernationRingLayer == nil, "a live tab has a ring")
        cell.update(item: item(dormant: true))
        try #require(cell.hibernationRingLayer != nil)
        cell.update(item: item(dormant: false))
        #expect(cell.hibernationRingLayer == nil, "a woken tab keeps its ring")
        #expect(CATransform3DIsIdentity(cell.iconLayer.transform), "a woken tab's favicon stays shrunk")
        #expect(!cell.iconLayer.masksToBounds && cell.iconLayer.cornerRadius == 0)
    }

    @Test func aTabThatHibernatesInTheStripAnimatesAndReduceMotionDoesNotMoveIt() throws {
        let speed = DesignSettings.shared.animationSpeed
        DesignSettings.shared.animationSpeed = .fast
        defer { DesignSettings.shared.animationSpeed = speed }
        Motion.reduceMotionOverride = false
        let cell = TabCell(item: item(dormant: false))
        cell.update(item: item(dormant: true))
        if Motion.indicators.animatesMovement {
            #expect(cell.iconLayer.animation(forKey: "transform") != nil, "the favicon jumps to its small size")
        }
        if Motion.indicators.duration(.hibernateRing) > 0 {
            #expect(cell.hibernationRingLayer?.animation(forKey: "opacity") != nil, "the ring appears at once")
        }

        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let reduced = TabCell(item: item(dormant: false))
        reduced.update(item: item(dormant: true))
        #expect(reduced.iconLayer.animation(forKey: "transform") == nil, "Reduce Motion still animates the favicon's size")
        #expect(abs(reduced.iconLayer.transform.m11 - 14.0 / 16.0) < 0.0001)
    }

    @Test func aTabCreatedHibernatedDoesNotAnimate() {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let cell = TabCell(item: item(dormant: true))
        #expect(cell.iconLayer.animation(forKey: "transform") == nil)
        #expect(cell.hibernationRingLayer?.animation(forKey: "opacity") == nil)
    }

    /// Chrome's `DottedIcon`: one 160° arc on the leading side, four 25° arcs, 20° gaps.
    @Test func theRingHasChromesArcs() {
        let arcs = TabCell.hibernationRingArcs.map { [Double($0.0), Double($0.1)] }
        #expect(arcs == [[100, 160], [280, 25], [325, 25], [10, 25], [55, 25]])
        let box = TabCell.hibernationRingPath(in: CGRect(x: 0, y: 0, width: 20, height: 20), stroke: 1.5).boundingBoxOfPath
        // A 9.25 radius circle (inset by half the stroke): the long arc reaches the leading edge;
        // 0°, 90° and 270° fall in gaps, so the other sides stop at cos 10° of the radius.
        let radius = 9.25, near = 9.25 * cos(10 * Double.pi / 180)
        #expect(abs(box.minX - (10 - radius)) < 0.01)
        #expect(abs(box.width - (radius + near)) < 0.01)
        #expect(abs(box.height - 2 * near) < 0.01)
    }
}
