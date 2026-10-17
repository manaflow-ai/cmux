import AppKit
import Testing
@testable import CmuxCEF

/// Window-level native UI (the command palette, a divider band) over every
/// Chromium page of a window: the page leaves a hole there (design spec §0.9).
@MainActor
@Suite struct CEFWindowOcclusionTests {
    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        return window
    }

    private func area(_ rects: [CGRect]) -> CGFloat {
        rects.reduce(0) { $0 + $1.width * $1.height }
    }

    @Test func windowRectsBecomeHolesInEveryHostOfTheWindow() throws {
        let window = makeWindow()
        let host = CEFHostView(frame: CGRect(x: 100, y: 50, width: 200, height: 150))
        try #require(window.contentView).addSubview(host)

        CEFWindowOcclusion.registry(for: window).setRects([CGRect(x: 150, y: 100, width: 100, height: 50)],
                                                          for: "palette")

        #expect(host.allOcclusionRects.contains(CGRect(x: 50, y: 50, width: 100, height: 50)))
        // The separator row stays.
        #expect(host.allOcclusionRects.contains(CGRect(x: 0, y: 149, width: 200, height: 1)))
        #expect(CEFWindowOcclusion.registry(for: window).hostViews.contains { $0 === host })
    }

    @Test func windowRectsOutsideTheHostMakeNoHole() throws {
        let window = makeWindow()
        let host = CEFHostView(frame: CGRect(x: 100, y: 50, width: 200, height: 150))
        try #require(window.contentView).addSubview(host)

        CEFWindowOcclusion.registry(for: window).setRects([CGRect(x: 0, y: 0, width: 50, height: 50)], for: "palette")

        #expect(host.allOcclusionRects == [CGRect(x: 0, y: 149, width: 200, height: 1)])
    }

    /// A panel hole (find bar) under the palette's hole: overlapping holes
    /// would cancel in the fork's even-odd mask, so they are joined.
    @Test func overlappingPanelAndWindowHolesAreJoinedWithoutOverlap() throws {
        let window = makeWindow()
        let host = CEFHostView(frame: CGRect(x: 0, y: 0, width: 200, height: 150))
        try #require(window.contentView).addSubview(host)
        host.occlusionRects = [CGRect(x: 0, y: 0, width: 100, height: 100)]

        CEFWindowOcclusion.registry(for: window).setRects([CGRect(x: 50, y: 50, width: 100, height: 60)],
                                                          for: "palette")

        let holes = host.allOcclusionRects
        for (index, hole) in holes.enumerated() {
            for other in holes[(index + 1)...] {
                #expect(!hole.intersects(other))
            }
        }
        // 100x100 + 100x60 - 50x50 overlap + the 200 pt separator row.
        #expect(area(holes) == 10_000 + 6_000 - 2_500 + 200)
    }

    @Test func changingTheWindowRectsAsksTheHostsOfThatWindowToUpdate() async throws {
        let window = makeWindow()
        let otherWindow = makeWindow()
        let host = CEFHostView(frame: CGRect(x: 0, y: 0, width: 200, height: 150))
        let otherHost = CEFHostView(frame: CGRect(x: 0, y: 0, width: 200, height: 150))
        try #require(window.contentView).addSubview(host)
        try #require(otherWindow.contentView).addSubview(otherHost)

        await confirmation("a page of another window stays", expectedCount: 0) { otherUpdate in
            let otherToken = NotificationCenter.default.addObserver(
                forName: CEFHostView.geometryDidChange, object: otherHost, queue: nil
            ) { _ in otherUpdate() }
            defer { NotificationCenter.default.removeObserver(otherToken) }

            await confirmation("the host re-reads its holes", expectedCount: 1) { confirm in
                let token = NotificationCenter.default.addObserver(
                    forName: CEFHostView.geometryDidChange, object: host, queue: nil
                ) { _ in confirm() }
                defer { NotificationCenter.default.removeObserver(token) }

                let registry = CEFWindowOcclusion.registry(for: window)
                registry.setRects([CGRect(x: 10, y: 10, width: 20, height: 20)], for: "palette")
                // Equal rects cost nothing.
                registry.setRects([CGRect(x: 10, y: 10, width: 20, height: 20)], for: "palette")
            }
        }
    }

    @Test func aHostThatLeavesTheWindowIsNoLongerOneOfItsPages() throws {
        let window = makeWindow()
        let host = CEFHostView(frame: CGRect(x: 0, y: 0, width: 200, height: 150))
        try #require(window.contentView).addSubview(host)
        host.removeFromSuperview()

        #expect(CEFWindowOcclusion.registry(for: window).hostViews.isEmpty)
    }

    /// A page at the window's bottom-left corner is clipped to the window's
    /// rounded corner; one away from every corner keeps its plain rect.
    @Test func pagesAtAWindowCornerAreClippedToIt() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 150)
        let corner = CEFHostView.cornerClip(bounds: bounds, windowRect: CGRect(x: 0, y: 0, width: 400, height: 300),
                                            radius: 10)
        #expect(corner != nil)
        #expect(corner?.contains(CGPoint(x: 0.5, y: 0.5)) == false)
        #expect(corner?.contains(CGPoint(x: 100, y: 75)) == true)
        #expect(corner?.contains(CGPoint(x: 199.5, y: 0.5)) == true)

        let inside = CEFHostView.cornerClip(bounds: bounds, windowRect: CGRect(x: -100, y: -50, width: 400, height: 300),
                                            radius: 10)
        #expect(inside == nil)
        #expect(CEFHostView.cornerClip(bounds: bounds, windowRect: CGRect(x: 0, y: 0, width: 400, height: 300),
                                       radius: 0) == nil)
    }
}
