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

    @Test func hoverLightsADimBandOnTheLine() {
        let view = handle()
        view.setHovered(true)
        #expect(view.glow.state == .hovered)
        // A split's band is its line (1 pt here): the uncovered line stays the line (``aLitSplitBandStaysInsideItsLine``).
        #expect(abs(view.lineFrameInSuperview.width - view.lineThickness) < 0.001)
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
        edge.showsIdleLine = false
        #expect(!edge.isLineVisible)
        edge.setHovered(true)
        #expect(edge.glow.isLit)
        #expect(edge.isLineVisible)
    }

    /// Under `layout.paneSeparation` none (the flat-sidebar-line look) hover keeps showing
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

    /// The lit line glows by itself: no shadow, blur or halo bleeds past its edges (Leo, 2026-11-07:
    /// "keep the line itself's glow, but don't make it glow like it's an actual light bulb").
    @Test func theLitBandHasNoBloomPastTheLine() {
        let view = handle()
        view.setHovered(true)
        let layers = [view.glow.layer] + (view.glow.layer.sublayers ?? [])
        for layer in layers {
            #expect(layer.shadowOpacity == 0)
            #expect(layer.filters == nil && layer.backgroundFilters == nil)
        }
        #expect(DividerGlowBand.reach == DividerGlowBand.coreThickness / 2, "the band reaches no further than its core")
        #expect(abs(view.glow.extent.width - min(view.lineThickness, DividerGlowBand.coreThickness)) < 0.001)
    }

    /// RESIZE P0 5 (px-col-drag-2-s1r, cmux21, 120 Hz, scale 2): a split's 1 pt line fills the whole gap between its panes,
    /// and the 2 pt band centered on it lit 0.5 pt of each pane in every drag frame: the terminal's edge showed 1 device px
    /// short and the page's 1 device px late (its occlusion hole is the lit band), a 1 pt seam the m20 judge failed in
    /// frames 211-347. The band lights the line itself and nothing past it: on a split it is as wide as the line.
    @Test func aLitSplitBandStaysInsideItsLine() throws {
        let view = handle()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        window.contentView?.addSubview(view)
        let line = view.lineFrameInSuperview
        #expect(abs(line.width - view.lineThickness) < 0.001, "SETUP: the resting line is not the divider's line")
        view.setHovered(true)
        #expect(view.lineFrameInSuperview == line, "hovered, the band covers \(view.lineFrameInSuperview), past the line \(line)")
        view.setHovered(false)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 103, y: 100), modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        view.mouseDown(with: down)
        #expect(view.glow.state == .dragging)
        #expect(view.lineFrameInSuperview == line, "dragging, the band covers \(view.lineFrameInSuperview), past the line \(line)")
        view.cancelOperation(nil)
    }

    /// Only a split's band follows its line: a row or column edge sits in a gap between panes, so its band keeps the
    /// full core (the 1 pt row-edge line does not thin it).
    @Test func edgeBandsKeepTheirFullCore() {
        for kind: DividerHandleView.Kind in [.rowEdge(ColumnID("column"), RowID("row")), .columnEdge(ColumnID("column"))] {
            let edge = handle(kind)
            edge.setHovered(true)
            #expect(abs(edge.glow.extent.width - DividerGlowBand.coreThickness) < 0.001, "\(kind): band \(edge.glow.extent)")
        }
    }

    @Test func bandOpacityIsZeroAtRestAndFullWhileDragging() {
        #expect(DividerGlowBand.opacity(.rest) == 0)
        #expect(DividerGlowBand.opacity(.hovered) > 0 && DividerGlowBand.opacity(.hovered) < 1)
        #expect(DividerGlowBand.opacity(.dragging) == 1)
    }
}
