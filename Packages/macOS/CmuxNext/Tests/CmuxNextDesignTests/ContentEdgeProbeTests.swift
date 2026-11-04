#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// The S7 live-resize probe's content edges (`liveResize.*_edge_err_pt`): a pane content that fills its area measures
/// 0; one whose frame is off by some points measures those points against its area, its pane and its tab strip, from its
/// view frame and from its layer once AppKit placed the layer; a pane whose AREA is off measures against the pane and
/// strip, not the area (the area is then not the reference that can hide it).
@MainActor
@Suite(.serialized, .closesItsWindows)
struct ContentEdgeProbeTests {
    final class Leaf: NSView {}
    final class Pane: NSView {}
    final class Strip: NSView {}

    @Test func itMeasuresHowFarAPaneContentIsFromItsAreaPaneAndStrip() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        root.wantsLayer = true
        window.contentView = root
        let pane = Pane(frame: NSRect(x: 20, y: 10, width: 200, height: 230))
        root.addSubview(pane)
        let strip = Strip(frame: NSRect(x: 0, y: 200, width: 180, height: 30))
        pane.addSubview(strip)
        let area = PaneContentAreaView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        pane.addSubview(area)
        let leaf = Leaf(frame: area.bounds)
        leaf.wantsLayer = true
        area.addSubview(leaf)
        window.orderFrontRegardless()
        root.layoutSubtreeIfNeeded()
        CATransaction.flush()
        var probe = ContentEdgeProbe()
        probe.contentClassNames = [String(describing: Leaf.self)]
        probe.paneClassName = String(describing: Pane.self)
        probe.stripClassName = String(describing: Strip.self)

        let filled = try #require(probe.measure(in: window), "the probe found no content")
        #expect(filled.views == 1 && filled.area == 0 && filled.areaLayer == 0 && filled.pane == 0 && filled.paneLayer == 0
                && filled.strip == 0 && filled.stripLayer == 0, "a content that fills its area: \(filled)")

        leaf.frame = NSRect(x: 12, y: 0, width: 180, height: 200)
        CATransaction.flush()
        let off = try #require(probe.measure(in: window))
        #expect(off.area == 12 && off.areaLayer == 12, "against the area: \(off)")
        #expect(off.pane == 12 && off.paneLayer == 12 && off.strip == 12 && off.stripLayer == 12, "against the pane and strip: \(off)")

        // The area itself (with its content) off the pane: the area measure cannot see it, the pane and strip ones do.
        leaf.frame = area.bounds
        area.frame = NSRect(x: 22, y: 0, width: 200, height: 200)
        CATransaction.flush()
        let areaOff = try #require(probe.measure(in: window))
        #expect(areaOff.area == 0, "the area measure: \(areaOff)")
        #expect(areaOff.pane == 22 && areaOff.strip == 22 && areaOff.paneLayer == 22, "the pane and strip measures: \(areaOff)")
    }
}
#endif
