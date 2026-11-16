import AppKit
@testable import CmuxNextLayout
import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// A zoom dims the other panes for the time of its motion only. The dim is one view in the overlay plane
/// (above pages too), found here by its identifier: plain parts around the zooming pane's rect, one opacity.
/// It starts in the frame the pane starts in, turns with the pane on a second key from the value it has,
/// and is gone in the frame the pane lands in: a zoom at rest and an unzoom at rest draw nothing more than
/// before, and the view is out of the plane. Its amount is the one token (`Palette.zoomDim`) times the part
/// of the pane's way that is done. Frames step at a fixed 120 Hz dt, so every assertion is about frame N,
/// not wall time.
@MainActor
@Suite(.closesItsWindows)
struct PaneZoomDimsOthersTests {
    typealias Screen = PaneZoomMotionTests.Screen

    static let dimIdentifier = "pane.zoom.dim"

    /// What the dim shows now, in the root's coordinates.
    struct Dim {
        var opacity: CGFloat
        var parts: [CGRect]
    }

    /// The dim as it shows now; nil when the plane has no dim view, or it is hidden or clear.
    static func dim(_ screen: Screen) -> Dim? {
        let plane = screen.root.overlayPlane
        guard let view = plane.subviews.first(where: { $0.identifier?.rawValue == dimIdentifier }),
              !view.isHidden, view.alphaValue > 0 else { return nil }
        let parts = (view.layer?.sublayers ?? []).filter { !$0.isHidden && !$0.frame.isEmpty }
            .map { screen.root.convert($0.frame, from: view) }
        return Dim(opacity: view.alphaValue, parts: parts)
    }

    /// The dim view is in the overlay plane, shown or not: at rest it must be out of it, not hidden in it.
    static func inPlane(_ screen: Screen) -> Bool {
        screen.root.overlayPlane.subviews.contains { $0.identifier?.rawValue == dimIdentifier }
    }

    /// `host`'s frame in the root's coordinates.
    static func rect(_ host: PaneHostView, in screen: Screen) -> CGRect {
        screen.root.convert(host.frame, from: host.superview)
    }

    /// The faults of `dim` in this frame: a part over the zooming pane's content, or a shown point of
    /// another pane that no part covers.
    static func faults(_ dim: Dim, zooming pane: PaneID, in screen: Screen) -> [String] {
        guard let host = screen.root.context.hosts[pane], host.superview != nil else { return ["the zooming pane has no host"] }
        var faults: [String] = []
        let content = screen.root.convert(host.contentRect, from: host).insetBy(dx: 1, dy: 1)
        for part in dim.parts where part.intersects(content) {
            faults.append("a part \(part) dims the zooming pane's content \(content)")
        }
        let front = rect(host, in: screen)
        for (id, other) in screen.root.context.hosts where id != pane && other.superview != nil && !other.isHidden {
            let frame = rect(other, in: screen).insetBy(dx: 2, dy: 2)
            let points = [CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY),
                          CGPoint(x: frame.minX, y: frame.maxY), CGPoint(x: frame.maxX, y: frame.maxY),
                          CGPoint(x: frame.midX, y: frame.midY)]
            for point in points where !front.insetBy(dx: -2, dy: -2).contains(point) {
                if !dim.parts.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(point) }) {
                    faults.append("\(id.rawValue) shows undimmed at \(point)")
                }
            }
        }
        return faults
    }

    static func isZooming(_ screen: Screen) -> Bool { screen.screen?.zoomMotion.pane != nil }

    @Test(arguments: ["p1", "p4", "p2"])
    func aZoomDimsTheOtherPanesFromItsFirstFrameUntilItLands(zoomed: String) throws {
        let screen = Screen(PaneZoomMotionTests.grid2)
        defer { screen.window.closeAfterTest() }
        let pane = PaneID(zoomed)
        #expect(Self.dim(screen) == nil, "a dim shows at rest before the zoom")
        #expect(!Self.inPlane(screen), "the dim view is in the plane at rest before the zoom")
        let startWidth = try #require(screen.hostSize(pane)?.width, "SETUP: the pane has no host before the zoom")
        screen.zoom(pane)
        var last: CGFloat = 0, dimmed = 0, landed: Int?
        // Each frame's opacity with the zooming pane's width in it: read against the whole way after the land.
        var samples: [(frame: Int, opacity: CGFloat, width: CGFloat)] = []
        for frame in 1...120 {
            screen.step()
            guard Self.isZooming(screen) else {
                landed = frame
                break
            }
            let dim = try #require(Self.dim(screen), "frame \(frame): the pane zooms and no dim shows")
            dimmed += 1
            #expect(dim.opacity > 0 && dim.opacity < 1, "frame \(frame): the dim's opacity is \(dim.opacity)")
            #expect(dim.opacity >= last - 0.000_001, "frame \(frame): the dim went back from \(last) to \(dim.opacity)")
            last = dim.opacity
            if let width = screen.hostSize(pane)?.width { samples.append((frame, dim.opacity, width)) }
            let faults = Self.faults(dim, zooming: pane, in: screen)
            #expect(faults.isEmpty, "frame \(frame): \(faults.joined(separator: "; "))")
        }
        #expect(dimmed >= 10, "the dim showed in \(dimmed) frames of the zoom")
        let landing = try #require(landed, "the zoom did not land in 120 frames")
        // The landing frame: the pane covers the others, which are let go, and no dim is left to draw.
        #expect(Self.dim(screen) == nil, "frame \(landing): the zoom landed and the dim still shows")
        #expect(!Self.inPlane(screen), "frame \(landing): the zoom landed and the dim view is still in the plane")
        // The amount is the token: the frame before the land shows nearly all of it and never more.
        let whole = Palette.zoomDim
        #expect(last <= whole + 0.000_001 && last >= whole * 0.9, "the dim reached \(last); the token is \(whole)")
        // The pane's own spring: in each frame the dim is as far as the pane is on its way.
        let endWidth = try #require(screen.hostSize(pane)?.width, "the zoomed pane has no host")
        try #require(abs(endWidth - startWidth) > 100, "SETUP: the zoom changed the pane's width from \(startWidth) to \(endWidth)")
        #expect(samples.count == dimmed, "\(samples.count) of \(dimmed) frames had the pane's width")
        for sample in samples {
            let done = (sample.width - startWidth) / (endWidth - startWidth)
            #expect(abs(sample.opacity / whole - done) <= 0.02,
                    "frame \(sample.frame): the dim is at \(sample.opacity / whole) of its way, the pane at \(done) of its own")
        }
        for other in PaneZoomMotionTests.grid2.panes where other != pane {
            #expect(screen.root.context.hosts[other]?.superview == nil, "frame \(landing): \(other.rawValue) is still shown under the landed zoom")
        }
        screen.step()
        #expect(Self.dim(screen) == nil, "a dim shows over a zoom at rest")
    }

    @Test func anUnzoomShowsTheOthersDimmedAndTheDimGoesWithThePane() throws {
        let screen = Screen(PaneZoomMotionTests.grid2)
        defer { screen.window.closeAfterTest() }
        screen.zoom("p1")
        var peak: CGFloat = 0
        for _ in 1...120 {
            screen.step()
            peak = max(peak, Self.dim(screen)?.opacity ?? 0)
            if !Self.isZooming(screen) { break }
        }
        try #require(!Self.isZooming(screen), "SETUP: the zoom did not land")
        try #require(peak > 0, "the zoom showed no dim")
        let zoomedWidth = try #require(screen.hostSize("p1")?.width, "SETUP: the zoomed pane has no host")
        screen.unzoom()
        var last = CGFloat.infinity, dimmed = 0, landed: Int?
        // Each frame's opacity with the pane's width in it: read against the whole way back after the land.
        var samples: [(frame: Int, opacity: CGFloat, width: CGFloat)] = []
        for frame in 1...120 {
            screen.step()
            guard Self.isZooming(screen) else {
                landed = frame
                break
            }
            let dim = try #require(Self.dim(screen), "frame \(frame): the pane goes back and no dim shows")
            dimmed += 1
            // The first frame finds the others as dim as the zoom left them when it covered them.
            if frame == 1 { #expect(dim.opacity >= peak * 0.8, "the unzoom's first frame dims at \(dim.opacity), the zoom reached \(peak)") }
            #expect(dim.opacity <= last + 0.000_001, "frame \(frame): the dim rose from \(last) to \(dim.opacity)")
            last = dim.opacity
            if let width = screen.hostSize("p1")?.width { samples.append((frame, dim.opacity, width)) }
            let faults = Self.faults(dim, zooming: "p1", in: screen)
            #expect(faults.isEmpty, "frame \(frame): \(faults.joined(separator: "; "))")
        }
        #expect(dimmed >= 10, "the dim showed in \(dimmed) frames of the unzoom")
        _ = try #require(landed, "the unzoom did not land in 120 frames")
        #expect(Self.dim(screen) == nil, "the unzoom landed and the dim still shows")
        #expect(!Self.inPlane(screen), "the unzoom landed and the dim view is still in the plane")
        #expect(last < peak * 0.1, "the dim was at \(last) of \(peak) in the frame before the unzoom landed")
        // The pane's own spring on the way back too: in each frame the dim has as much left as the pane has.
        let whole = Palette.zoomDim
        let restWidth = try #require(screen.hostSize("p1")?.width, "the pane has no host after the unzoom")
        try #require(abs(zoomedWidth - restWidth) > 100, "SETUP: the unzoom changed the pane's width from \(zoomedWidth) to \(restWidth)")
        #expect(samples.count == dimmed, "\(samples.count) of \(dimmed) frames had the pane's width")
        for sample in samples {
            let left = (sample.width - restWidth) / (zoomedWidth - restWidth)
            #expect(abs(sample.opacity / whole - left) <= 0.02,
                    "frame \(sample.frame): the dim has \(sample.opacity / whole) of its way left, the pane \(left) of its own")
        }
    }

    @Test func aSecondKeyInMidZoomTurnsTheDimBackFromTheValueItHas() throws {
        let screen = Screen(PaneZoomMotionTests.grid2)
        defer { screen.window.closeAfterTest() }
        screen.zoom("p1")
        var opacities: [CGFloat] = []
        for frame in 1...6 {
            screen.step()
            opacities.append(try #require(Self.dim(screen), "frame \(frame): the pane zooms and no dim shows").opacity)
        }
        try #require(Self.isZooming(screen), "SETUP: the zoom landed in 6 frames")
        let before = opacities[5], rate = abs(opacities[5] - opacities[4])
        screen.unzoom()
        screen.step()
        let turned = try #require(Self.dim(screen), "the second key's first frame shows no dim").opacity
        // No jump: the frame after the key is as near the frame before it as two frames of the zoom were.
        #expect(abs(turned - before) <= 2 * rate + 0.005, "the dim jumped from \(before) to \(turned) at the second key")
        var last = turned, highest = turned, landed = false
        for frame in 8...240 {
            screen.step()
            guard Self.isZooming(screen) else {
                landed = true
                break
            }
            let dim = try #require(Self.dim(screen), "frame \(frame): the pane goes back and no dim shows")
            highest = max(highest, dim.opacity)
            last = dim.opacity
        }
        #expect(landed, "the turned zoom did not land")
        #expect(highest <= before + 2 * rate + 0.005, "the dim went on to \(highest) after the second key at \(before)")
        #expect(last < before, "the dim did not go back: \(last) in the frame before the land, \(before) at the second key")
        #expect(Self.dim(screen) == nil, "the turned zoom landed and the dim still shows")
        #expect(!Self.inPlane(screen), "the turned zoom landed and the dim view is still in the plane")
    }

    @Test func reduceMotionShowsNoDim() throws {
        let screen = Screen(PaneZoomMotionTests.grid2, reduceMotion: true)
        defer { screen.window.closeAfterTest() }
        screen.zoom("p1")
        #expect(Self.dim(screen) == nil, "Reduce Motion: a dim shows in the zoom's turn")
        for frame in 1...4 {
            screen.step()
            #expect(Self.dim(screen) == nil, "Reduce Motion: a dim shows in frame \(frame) of the zoom")
        }
        screen.unzoom()
        for frame in 1...4 {
            screen.step()
            #expect(Self.dim(screen) == nil, "Reduce Motion: a dim shows in frame \(frame) of the unzoom")
        }
    }
}
