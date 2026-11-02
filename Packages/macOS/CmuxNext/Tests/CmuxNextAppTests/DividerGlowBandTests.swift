import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// A divider lights an accent band while hovered or dragged and shows nothing extra at rest
/// (Leo, 2026-10-29: "having that themed color band would be quite nice for our app as well").
@MainActor @Suite(.closesItsWindows)
struct DividerGlowBandTests {
    private func handle(_ kind: DividerHandleView.Kind = .split(SplitID("split"))) -> DividerHandleView {
        let view = DividerHandleView(kind: kind, axis: .horizontal)
        view.frame = CGRect(x: 100, y: 0, width: 7, height: 300)
        view.layoutSubtreeIfNeeded()
        return view
    }

    @Test func restingDividerShowsNoBandAndKeepsItsLine() {
        let view = handle()
        #expect(view.glow.state == .rest)
        #expect(!view.glow.isLit)
        #expect(view.glow.extent.isNull)
        // At rest the reported line is the line alone, as before.
        #expect(view.lineFrameInSuperview.width == view.lineThickness)
    }

    @Test func hoverLightsADimBandAndWidensTheUncoveredLine() {
        let view = handle()
        view.setHovered(true)
        #expect(view.glow.state == .hovered)
        let reach = DividerGlowBand.reach
        #expect(abs(view.lineFrameInSuperview.width - 2 * reach) < 0.001)
        #expect(abs(view.lineFrameInSuperview.midX - view.frame.midX) < 0.001)
        view.setHovered(false)
        #expect(view.glow.state == .rest)
    }

    @Test func dragLightsTheFullBandUntilRelease() throws {
        let view = handle()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        window.contentView?.addSubview(view)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 103, y: 100), modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: CGPoint(x: 103, y: 100), modifierFlags: [], timestamp: 0,
                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        view.mouseDown(with: down)
        #expect(view.glow.state == .dragging)
        view.mouseUp(with: up)
        #expect(view.glow.state == .rest)
    }

    @Test func edgeHandlesLightTheSameBand() {
        let edge = handle(.columnEdge(ColumnID("column")))
        #expect(!edge.isLineVisible)
        edge.setHovered(true)
        #expect(edge.glow.isLit)
        #expect(edge.isLineVisible)
    }

    /// Under `layout.paneSeparation` none (the app's default flat-sidebar-line look) hover keeps showing
    /// nothing, as before, but a drag still lights the band: it is the drag's cue.
    @Test func paneSeparationNoneLightsTheBandOnlyWhileDragging() throws {
        let view = handle()
        view.showsActiveLine = false
        view.setHovered(true)
        #expect(view.glow.state == .rest)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        window.contentView?.addSubview(view)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 103, y: 100), modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        view.mouseDown(with: down)
        #expect(view.glow.state == .dragging)
        #expect(view.isLineVisible, "the lit band is reported to the page as native pixels")
        view.cancelOperation(nil)
        #expect(view.glow.state == .rest, "Escape ends the drag and its band")
    }

    /// Going out is instant, so a pane divider's Chromium hole, which closes with the state change,
    /// never cuts off a halo mid-fade.
    @Test func backToRestPutsTheBandOutAtOnce() {
        let band = DividerGlowBand()
        band.set(.dragging)
        band.set(.rest)
        #expect(band.layer.opacity == 0)
        #expect(band.layer.animation(forKey: "opacity") == nil)
        #expect(band.extent.isNull)
    }

    @Test func bandOpacityIsZeroAtRestAndFullWhileDragging() {
        #expect(DividerGlowBand.opacity(.rest) == 0)
        #expect(DividerGlowBand.opacity(.hovered) > 0 && DividerGlowBand.opacity(.hovered) < 1)
        #expect(DividerGlowBand.opacity(.dragging) == 1)
    }
}
