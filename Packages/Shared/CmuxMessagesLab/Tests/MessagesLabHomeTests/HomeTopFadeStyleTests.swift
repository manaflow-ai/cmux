import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// Home's chat top under the avatar and the "Chief >" pill, one ``HomeTopFadeStyle`` at a time
/// (Lawrence 2026-10-23: "make variations of how we do fade at top in chief"). Each style draws at
/// most one band over the rows, gives the rows the alpha it promises at the pill and below it, and a
/// live switch leaves nothing of the style before it.
///
/// The test reads the pane's views and the alpha the transcript clip's mask gives the rows (the
/// mask rendered on its own); blurs only draw on screen (cmux-galleries/chief-top-fade).
@MainActor @Suite(.serialized) struct HomeTopFadeStyleTests {
    /// The rows' alpha at each pane y (top-down), from the transcript clip's mask.
    private static func rowAlpha(_ demo: MessagesWindowView, at ys: [CGFloat]) throws -> [CGFloat] {
        guard let mask = demo.clip.layer.mask else { return ys.map { _ in 1 } }
        let size = demo.clip.bounds.size
        let w = max(1, Int(size.width)), h = max(1, Int(size.height))
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: mask.frame.minX, y: mask.frame.minY)
        mask.render(in: ctx)
        let data = try #require(ctx.data)
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        return ys.map { y in
            let row = min(h - 1, max(0, Int(y)))
            return CGFloat(px[row * w * 4 + (w / 2) * 4 + 3]) / 255
        }
    }

    /// The bands over the rows a style may draw: the glass band, the style's own band, Messages' bar.
    private static func bands(_ host: HostView) -> (glass: Bool, own: HomeTopFadeStyle?, messages: Bool) {
        (host.headerGlass?.superview === host, host.topFadeView.flatMap { $0.superview === host ? $0.style : nil },
         !host.headerBackdrop.isHidden)
    }

    @Test(arguments: HomeTopFadeStyle.allCases)
    func eachStyleDrawsItsBandAndMask(style: HomeTopFadeStyle) async throws {
        let rig = try await HomeChatRig(history: 300, width: 620)
        defer { rig.stop() }
        let view = rig.view
        view.setTopFadeStyle(style)
        let host = view.controller.host
        host.paneHeader.title = "Chief"
        rig.window.contentView?.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        let demo = try #require(view.controller.demo)
        #expect(view.topFadeStyle == style)
        #expect(!host.paneHeader.bare, "a header style keeps the avatar and the pill")

        let b = Self.bands(host)
        #expect(b.glass == (style == .glassBand))
        #expect(b.messages == (style == .messagesBar))
        let ownBand: Set<HomeTopFadeStyle> = [.progressiveBlur, .materialHairline, .edgeShadow, .backgroundTint]
        #expect(b.own == (ownBand.contains(style) ? style : nil))
        if let own = host.topFadeView {
            // Under the header controls, over the rows; takes no clicks.
            let order = host.subviews
            #expect((order.firstIndex(of: own) ?? .max) < (order.firstIndex(of: host.paneHeader) ?? -1))
            #expect(own.frame.minY == 0 && own.frame.width == host.bounds.width)
            #expect(own.hitTest(NSPoint(x: 10, y: 10)) == nil)
        }

        let pillMid = PaneHeaderView.pillCenterY, pillBottom = HomeTopFadeView.pillBottom
        let ys: [CGFloat] = [2, pillMid, pillBottom + 2, pillBottom + 40, host.bounds.height / 2]
        let a = try Self.rowAlpha(demo, at: ys)
        let label = zip(ys, a).map { "\($0): \($1)" }
        // Every style: full strength well below the header.
        #expect(a[3] >= 0.98 && a[4] >= 0.98, "rows below the header are dimmed: \(label)")
        switch style {
        case .glassBand, .materialHairline, .messagesBar:
            #expect(a.allSatisfy { $0 >= 0.98 }, "a band style masks the rows: \(label)")
        case .softMask:
            #expect(a[0] < 0.05 && a[1] > 0.4 && a[1] < 0.95, "soft fade: \(label)")
        case .progressiveBlur:
            #expect(a[0] < 0.3 && a[1] >= 0.98, "only the top edge fades under the blur: \(label)")
        case .edgeShadow, .belowPill:
            #expect(a[0] < 0.02 && a[1] < 0.02, "rows draw under the pill: \(label)")
        case .backgroundTint:
            // The tint covers them: the rows themselves keep full strength in an opaque pane.
            #expect(a.allSatisfy { $0 >= 0.98 }, "tint over an opaque pane masks the rows: \(label)")
        }
    }

    @Test func aLiveSwitchLeavesNothingOfTheStyleBefore() async throws {
        let rig = try await HomeChatRig(history: 300, width: 620)
        defer { rig.stop() }
        let view = rig.view
        let host = view.controller.host
        for style in HomeTopFadeStyle.allCases + HomeTopFadeStyle.allCases.reversed() {
            view.setTopFadeStyle(style)
            host.layoutSubtreeIfNeeded()
            let b = Self.bands(host)
            let drawn = [b.glass, b.own != nil, b.messages].filter { $0 }.count
            #expect(drawn <= 1, "\(style): \(drawn) bands over the rows")
            #expect(host.subviews.filter { $0 is HeaderGlassView || $0 is HomeTopFadeView }.count <= 1,
                    "\(style): a band of an earlier style is still in the pane")
        }
        #expect(view.topFadeStyle == .glassBand)
        #expect(view.headerGlass != nil)
        let demo = try #require(view.controller.demo)
        #expect(demo.topMaskStops.isEmpty, "the glass band masks the rows after a round trip")
    }

    @Test func theEdgeShadowShowsOnlyWhileRowsSitUnderTheCut() async throws {
        let rig = try await HomeChatRig(history: 300, width: 620)
        defer { rig.stop() }
        let view = rig.view
        view.setTopFadeStyle(.edgeShadow)
        let host = view.controller.host
        rig.window.contentView?.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        let demo = try #require(view.controller.demo)
        let band = try #require(host.topFadeView)
        #expect(demo.minOffset < demo.pinnedOffset, "the history fits: nothing to scroll")

        // At the newest rows, older rows sit above the cut: the shadow shows.
        demo.collection.contentOffset = CGPoint(x: 0, y: demo.pinnedOffset)
        demo.userScrolled()
        #expect(band.scrolledUnder)
        // Scrolled to the oldest loaded row, which rests under the header: no shadow.
        demo.collection.contentOffset = CGPoint(x: 0, y: demo.minOffset)
        demo.userScrolled()
        #expect(!band.scrolledUnder)
    }

    /// Main-thread cost of one scrolled frame per style (the scroll, the pane's layout and the
    /// transaction commit), 400 steps of 4 pt up and down the history. Written to
    /// `.build/top-fade-scroll.json` (a fleet step returns it with `--artifact`) for the gallery.
    /// The render server's blur cost is not in it: an offscreen test window composites nothing.
    /// Every style must stay well inside a 120 Hz frame (p95 under 4 ms).
    @Test func scrollingCostsNoFrameInAnyStyle() async throws {
        var report: [String: [String: Double]] = [:]
        for style in HomeTopFadeStyle.allCases {
            let rig = try await HomeChatRig(history: 300, width: 620)
            defer { rig.stop() }
            let view = rig.view
            view.setTopFadeStyle(style)
            rig.frame()
            let demo = try #require(view.controller.demo)
            let lo = demo.minOffset, hi = demo.pinnedOffset
            var y = hi, dir: CGFloat = -1
            var ms: [Double] = []
            for _ in 0..<400 {
                y += dir * 4
                if y <= lo || y >= hi { dir = -dir; y = min(max(y, lo), hi) }
                let t0 = DispatchTime.now().uptimeNanoseconds
                demo.collection.contentOffset = CGPoint(x: 0, y: y)
                demo.userScrolled()
                view.controller.host.layoutSubtreeIfNeeded()
                CATransaction.flush()
                ms.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
            }
            ms.sort()
            let median = ms[ms.count / 2], p95 = ms[ms.count * 95 / 100]
            report[style.rawValue] = ["median_ms": median, "p95_ms": p95, "max_ms": ms[ms.count - 1]]
            print("top-fade-scroll \(style.rawValue): median \(median) ms p95 \(p95) ms")
            #expect(p95 < 4, "\(style): p95 \(p95) ms per scrolled frame")
        }
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = package.appendingPathComponent(".build/top-fade-scroll.json")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: out)
    }
}
