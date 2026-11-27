import AppKit
@testable import CmuxNextBrowser
import Testing

/// cmux-ad m81, Lawrence 2026-11-09 ("cmd shift d animation is very bad for webviews, it pushes the whole webview up, then
/// resizes, so there is a lot of flickering"). A Chromium page's pixels reach the window through `CEFHostedPageView`: a
/// `CALayerHost` shows the root layer of the fork's Core Animation context, which the fork sizes to the page window
/// (`adoptDisplayLayers`). That root's size and the hosted view's size do not show in the same frame: on cmux21 at 120 Hz
/// (feat b2550aca5824, sd-cef-light-down-0) the root showed the next spring frame's height while the pane still showed
/// this frame's, and the page, held by its bottom-left corner, moved down as a whole by the difference (500, 209, 30 and
/// 4 device px in one split down) and then back. Whatever size the root has in a frame, the page's top-left corner stays
/// on its pane's page area's top-left corner: a split down, a split up and a split right only cut or uncover the page's
/// bottom or trailing edge.
@MainActor
@Suite struct CEFHostedPageAnchorTests {
    /// What a split's spring does to the page area in each frame.
    enum Split: CaseIterable {
        /// Cmd-Shift-D: the page's pane shrinks from its bottom (the top edge stays).
        case down
        /// Split Up: the page's pane shrinks from its top (the bottom edge stays).
        case up
        /// Cmd-D: the page's pane shrinks from its trailing edge (the leading edge stays).
        case right
    }

    /// The fork's root of a hosted page, as `-setLayerHosting:` makes it: unflipped, anchor and position zero, its bounds
    /// set from the page window's compositor view. The fake layer host shows it as its sublayer, as a `CALayerHost` shows
    /// its context's root.
    final class FakeContext {
        let root: CALayer = {
            let root = CALayer()
            root.anchorPoint = .zero
            root.position = .zero
            return root
        }()

        func makeLayerHost(_ id: UInt32) -> CALayer? {
            let host = CALayer()
            host.addSublayer(root)
            return host
        }

        func remoteRoot(_ id: UInt32) -> CALayer? { id == 7 ? root : nil }
    }

    static let pane = CGSize(width: 800, height: 600)
    /// A split's spring from the whole pane to half of it, frame by frame (the last is the rest).
    static let fractions: [CGFloat] = [1, 0.94, 0.72, 0.58, 0.52, 0.505, 0.5]

    /// The page area of the page's pane in each frame of `split`, in the pane's coordinates (not flipped).
    static func pageAreas(_ split: Split) -> [CGRect] {
        fractions.map { f in
            switch split {
            case .down: CGRect(x: 0, y: pane.height * (1 - f), width: pane.width, height: pane.height * f)
            case .up: CGRect(x: 0, y: 0, width: pane.width, height: pane.height * f)
            case .right: CGRect(x: 0, y: 0, width: pane.width * f, height: pane.height)
            }
        }
    }

    /// Films `split` and returns the frames where the page's content top-left corner was not on its page area's top-left
    /// corner, as (frame, where the content's top-left was, where the area's was), in the pane's coordinates. `rootLead`:
    /// the fork's root shows the next frame's size in each frame (+1, filmed on cmux21) or the frame before's (-1).
    static func film(_ split: Split, rootLead: Int) throws -> [(frame: Int, content: CGPoint, area: CGPoint)] {
        let context = FakeContext()
        let paneView = NSView(frame: NSRect(origin: .zero, size: pane))
        let areas = pageAreas(split)
        let page = CEFHostedPageView(frame: areas[0], makeLayerHost: context.makeLayerHost, remoteRoot: context.remoteRoot)
        paneView.addSubview(page)
        #expect(page.host(contextID: 7), "SETUP: the page is not hosted")
        context.root.bounds = CGRect(origin: .zero, size: areas[0].size)
        var moved: [(frame: Int, content: CGPoint, area: CGPoint)] = []
        for (index, area) in areas.enumerated() {
            page.frame = area
            let shown = areas[min(max(index + rootLead, 0), areas.count - 1)]
            context.root.bounds = CGRect(origin: .zero, size: shown.size)
            let layer = try #require(page.layer, "SETUP: the hosted page has no layer")
            // The root is not flipped: its top-left corner is (0, height) in its own coordinates.
            let inPage = layer.convert(CGPoint(x: 0, y: context.root.bounds.height), from: context.root)
            let content = page.convert(inPage, to: paneView)
            let areaTopLeft = CGPoint(x: area.minX, y: area.maxY)
            if abs(content.x - areaTopLeft.x) > 0.5 || abs(content.y - areaTopLeft.y) > 0.5 {
                moved.append((frame: index, content: content, area: areaTopLeft))
            }
        }
        return moved
    }

    @Test(arguments: Split.allCases, [1, -1])
    func aSplitNeverMovesThePageAsAWhole(_ split: Split, rootLead: Int) throws {
        let moved = try Self.film(split, rootLead: rootLead)
        #expect(moved.isEmpty, """
            split \(split) with the fork's root \(rootLead > 0 ? "a frame ahead" : "a frame behind"): the page moved as a \
            whole off its pane's top-left corner in \(moved.count) frames: \(moved.map { "frame \($0.frame) content \($0.content) area \($0.area)" })
            """)
    }

    /// A page whose context is not in this process (no root to read): the page shows as before, held by the root's
    /// bottom-left corner, never lost.
    @Test func aContextFromAnotherProcessStillShows() throws {
        let context = FakeContext()
        let page = CEFHostedPageView(frame: NSRect(x: 0, y: 0, width: 400, height: 300),
                                     makeLayerHost: context.makeLayerHost, remoteRoot: { _ in nil })
        #expect(page.host(contextID: 9))
        let host = try #require(page.layer?.sublayers?.first, "the page shows no layer host")
        #expect(host.position == .zero)
        #expect(context.root.anchorPoint == .zero)
    }
}
