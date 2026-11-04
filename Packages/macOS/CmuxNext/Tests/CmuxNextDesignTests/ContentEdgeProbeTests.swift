#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// The S7 live-resize probe's content edges (`liveResize.view_edge_err_pt`, `layer_edge_err_pt`): a pane content that
/// fills its area measures 0; one whose frame is off by some points measures those points, from its view frame and from
/// its layer once AppKit placed the layer.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct ContentEdgeProbeTests {
    final class Leaf: NSView {}

    @Test func itMeasuresHowFarAPaneContentIsFromItsArea() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        root.wantsLayer = true
        window.contentView = root
        let area = PaneContentAreaView(frame: NSRect(x: 20, y: 10, width: 200, height: 200))
        root.addSubview(area)
        let leaf = Leaf(frame: area.bounds)
        leaf.wantsLayer = true
        area.addSubview(leaf)
        window.orderFrontRegardless()
        root.layoutSubtreeIfNeeded()
        CATransaction.flush()
        var probe = ContentEdgeProbe()
        probe.contentClassNames = [String(describing: Leaf.self)]

        let filled = try #require(probe.measure(in: window), "the probe found no content")
        #expect(filled.views == 1 && filled.view == 0 && filled.layer == 0, "a content that fills its area: \(filled)")

        leaf.frame = NSRect(x: 12, y: 0, width: 180, height: 200)
        CATransaction.flush()
        let off = try #require(probe.measure(in: window))
        #expect(off.view == 12, "the view frame's largest edge distance: \(off.view)")
        #expect(off.layer == 12, "the layer's largest edge distance: \(off.layer)")
    }
}
#endif
