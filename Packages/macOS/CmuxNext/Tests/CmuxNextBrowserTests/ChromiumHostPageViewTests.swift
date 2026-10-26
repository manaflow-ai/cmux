import AppKit
@testable import CmuxNextBrowser
import Testing

/// The one view every hosted Chromium page shows in (p01-process-040): in-process layer hosting
/// and the Chromium host app use the same type; only who takes the page's input differs.
@MainActor
@Suite struct ChromiumHostPageViewTests {
    let frame = NSRect(x: 0, y: 0, width: 400, height: 300)

    func makePage(_ input: ChromiumHostPageView.InputTarget,
                  layerHost: @escaping (UInt32) -> CALayer? = { _ in CALayer() }) -> ChromiumHostPageView {
        ChromiumHostPageView(frame: frame, inputTarget: input, makeLayerHost: layerHost)
    }

    func makeWindow(holding page: ChromiumHostPageView) -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 500), styleMask: .borderless,
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let pane = NSView(frame: NSRect(x: 20, y: 30, width: 400, height: 300))
        window.contentView?.addSubview(pane)
        pane.addSubview(page)
        return (window, pane)
    }

    @Test func anInProcessPageLeavesItsInputToThePageWindow() {
        let page = makePage(.pageWindow)
        #expect(page.hitTest(NSPoint(x: 10, y: 10)) == nil)
        #expect(!page.acceptsFirstResponder)
        #expect(!page.acceptsFirstMouse(for: nil))
    }

    @Test func aHostModePageIsItsOwnInputTarget() {
        let page = makePage(.view)
        #expect(page.hitTest(NSPoint(x: 10, y: 10)) === page)
        #expect(page.acceptsFirstResponder)
        #expect(ChromiumHostPageView(frame: frame).inputTarget == .view)
    }

    @Test func theContextShowsInTheContentLayerAndAMissingLayerHostShowsNothing() {
        let page = makePage(.view)
        #expect(page.show(contextID: 9))
        #expect(page.contextID == 9)
        #expect(page.layer?.sublayers?.count == 1)
        #expect(page.layer?.sublayers?.first?.sublayers?.count == 1)
        #expect(page.show(contextID: 0))
        #expect(page.layer?.sublayers?.first?.sublayers?.isEmpty ?? true)

        let blank = makePage(.pageWindow, layerHost: { _ in nil })
        #expect(!blank.show(contextID: 7))
        #expect(blank.contextID == 0)
    }

    @Test func theBackgroundFillPaintsWhereNoContextShows() {
        let page = makePage(.view)
        #expect(page.layer?.backgroundColor == nil)
        let fill = CGColor(gray: 0.2, alpha: 1)
        page.backgroundFill = fill
        #expect(page.layer?.backgroundColor == fill)
        page.backgroundFill = nil
        #expect(page.layer?.backgroundColor == nil)
    }

    /// The crash page covers the page and takes the mouse in both modes; clearing the slot gives
    /// the page its input back.
    @Test func theCrashOverlayFillsThePageAndTakesTheMouse() {
        for input in [ChromiumHostPageView.InputTarget.pageWindow, .view] {
            let page = makePage(input)
            let crash = NSView()
            page.crashOverlay = crash
            #expect(crash.superview === page)
            #expect(crash.frame == page.bounds)
            #expect(page.hitTest(NSPoint(x: 10, y: 10)) === crash)

            let next = NSView()
            page.crashOverlay = next
            #expect(crash.superview == nil)
            #expect(next.superview === page)

            page.crashOverlay = nil
            #expect(next.superview == nil)
            #expect(page.hitTest(NSPoint(x: 10, y: 10)) === (input == .view ? page : nil))
        }
    }

    /// P8: the owner hears of the page's screen rect only when it changed.
    @Test func geometryIsReportedOnlyWhenThePresentedRectChanged() throws {
        let page = makePage(.view)
        var reports: [ChromiumHostGeometry] = []
        page.onGeometry = { reports.append($0) }
        let (window, pane) = makeWindow(holding: page)
        defer { page.removeFromSuperview(); window.close() }
        #expect(reports.count == 1)
        let first = try #require(reports.first)
        #expect(first.width == 400 && first.height == 300)
        #expect(first.screenX == Int32(window.frame.minX) + 20)
        #expect(first.screenY == Int32(window.frame.minY) + 30)

        page.setFrameSize(page.frame.size)
        page.presentedRectDidChange()
        #expect(reports.count == 1)

        // An ancestor moved: the page's own frame did not change.
        pane.setFrameOrigin(NSPoint(x: 50, y: 30))
        page.presentedRectDidChange()
        #expect(reports.count == 2)
        #expect(reports.last?.screenX == Int32(window.frame.minX) + 50)

        page.setFrameSize(NSSize(width: 200, height: 300))
        #expect(reports.count == 3)
        #expect(reports.last?.width == 200)

        // Leaving the window and coming back reports again: the host lost nothing it needs.
        page.removeFromSuperview()
        pane.addSubview(page)
        #expect(reports.count == 4)
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    @Test func firstResponderSendsFocusToTheHost() {
        let page = makePage(.view)
        var focus: [Int32] = []
        page.sink = { frame in if frame.kind == .focus { focus.append(frame.v[0]) } }
        let (window, _) = makeWindow(holding: page)
        defer { page.removeFromSuperview(); window.close() }
        #expect(window.makeFirstResponder(page))
        #expect(window.makeFirstResponder(nil))
        #expect(focus == [1, 0])
    }
    #endif
}
