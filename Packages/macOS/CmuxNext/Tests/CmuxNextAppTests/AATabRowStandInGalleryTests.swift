import AppKit
import CmuxNextDesign
import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// The tab-row stand-in gallery (Leo 2026-11-24: "man it's unsatisfying for the buttons to track the dragging of the
/// pane split dividers so poorly. it lags, it doesn't follow in lockstep"): a chat pane mid-drag, grown by a divider
/// while the page's own tools still draw where the pane was a few frames ago. `before`: the page's tools trail, a gap
/// between them and the pane's ⋮. `standin`: the pane's band (`PaneTabRowStandInView`, real) covers from where the page's
/// tools still are to the toolbar and draws them where the pane is now. `solo`: a chat alone in its pane (its tab hidden;
/// the band paints the row's hole fill). Light and dark. Written under `tab-row-standin-gallery/` and bundled to
/// `tab-row-standin-gallery.tar` for `cmux-ci run --artifact`. Runs only with `CMUX_TEST_REQUIRE_GUI=1`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AATabRowStandInGalleryTests {
    enum Look: String, CaseIterable {
        case before
        case standin
        case solo = "standin-solo"
    }

    static let tools = [PaneTabRowTool(id: "summary", symbol: "text.alignleft", label: "Summary"),
                        PaneTabRowTool(id: "terminal", symbol: "terminal", label: "Terminal"),
                        PaneTabRowTool(id: "browser", symbol: "globe", label: "Browser"),
                        PaneTabRowTool(id: "chat-menu", symbol: "ellipsis", label: "Chat")]

    static func render(_ look: Look, dark: Bool) throws -> CGImage {
        _ = NSApplication.shared
        let width: CGFloat = 560, height: CGFloat = 150, row: CGFloat = 36, lag: CGFloat = 46
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        root.appearance = window.appearance
        window.contentView = root
        let color = { (make: () -> NSColor) in root.performWithTheme { make().withAlphaComponent(1) }.cgColor }
        let page = color { Palette.pageBackground }
        root.layer?.backgroundColor = look == .solo ? page : color { Palette.stripBackground }
        // The chat's page under the row: transcript-like lines.
        let body = CALayer()
        body.frame = CGRect(x: 0, y: row, width: width, height: height - row)
        body.backgroundColor = page
        root.layer?.addSublayer(body)
        for line in 0..<5 {
            let bar = CALayer()
            bar.frame = CGRect(x: 18, y: row + 16 + CGFloat(line) * 18, width: CGFloat([380, 300, 420, 240, 340][line]), height: 7)
            bar.cornerRadius = 3
            bar.backgroundColor = color { Palette.separator }
            root.layer?.addSublayer(bar)
        }
        // The pane's own toolbar: ⋮ at the trailing end, in the drag's commit.
        let paneBar = PaneToolbarView(frame: .zero)
        paneBar.show(more: true, lit: true)
        let barWidth = paneBar.intrinsicContentSize.width
        paneBar.frame = CGRect(x: width - barWidth, y: 0, width: barWidth, height: row)
        root.addSubview(paneBar)
        let room = width - barWidth
        // The page's own tools, drawn by the page where the pane was `lag` points ago.
        let pageTools = PaneToolbarView(frame: .zero)
        pageTools.show(nativeItems: tools)
        pageTools.reveal.isEnabled = false
        let span = pageTools.intrinsicContentSize.width
        pageTools.frame = CGRect(x: room - lag - span, y: 0, width: span, height: row)
        root.addSubview(pageTools)
        if look != .solo {
            for (index, title) in ["Fix login flow", "Review #53143"].enumerated() {
                let tab = CATextLayer()
                tab.frame = CGRect(x: 8 + CGFloat(index) * 138, y: 6, width: 132, height: row - 12)
                tab.cornerRadius = 7
                tab.backgroundColor = index == 0 ? color { Palette.selectionFill } : nil
                tab.string = "  " + title
                tab.fontSize = 12
                tab.contentsScale = 2
                tab.foregroundColor = color { Palette.textPrimary }
                root.layer?.addSublayer(tab)
            }
        }
        if look != .before {
            let band = PaneTabRowStandInView(frame: .zero)
            root.addSubview(band, positioned: .below, relativeTo: paneBar)
            let left = room - lag - span
            band.show(PaneTabRowStandIn(frame: .zero, rim: PaneTabRowRim.height, tools: tools, fill: page),
                      at: CGRect(x: left, y: 0, width: room - left, height: row))
        }
        window.orderFrontRegardless()
        root.layoutSubtreeIfNeeded()
        CATransaction.flush()
        root.display()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        return try #require(rep.cgImage)
    }

    final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = root.appending(path: "tab-row-standin-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for look in Look.allCases {
            for (mode, dark) in [("light", false), ("dark", true)] {
                let image = try Self.render(look, dark: dark)
                let url = out.appending(path: "\(look.rawValue)-\(mode).png")
                let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
                CGImageDestinationAddImage(dest, image, nil)
                #expect(CGImageDestinationFinalize(dest))
            }
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "tab-row-standin-gallery.tar", "tab-row-standin-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }

    /// The band draws the tools trailing at its trailing edge, opaque under the rim and clear on it, and takes no clicks.
    @Test func theBandEndsItsToolsAtItsTrailingEdgeAndTakesNoClicks() throws {
        let band = PaneTabRowStandInView(frame: .zero)
        let fill = CGColor(gray: 0.5, alpha: 1)
        band.show(PaneTabRowStandIn(frame: .zero, rim: 1, tools: Self.tools, fill: fill), at: CGRect(x: 40, y: 0, width: 200, height: 36))
        #expect(band.frame == CGRect(x: 40, y: 0, width: 200, height: 36))
        #expect(band.toolbar.nativeItems == Self.tools)
        #expect(band.toolbar.reveal.isEnabled == false, "Minimal Mode hid the stand-in's tools at rest")
        let last = try #require(band.toolbar.nativeButtons.last)
        #expect(abs(band.toolbar.convert(last.frame, to: band).maxX - band.bounds.maxX) <= 0.5)
        let plate = try #require(band.layer?.sublayers?.first)
        #expect(plate.backgroundColor == fill)
        #expect(plate.frame.minY == 1)
        #expect(band.layer?.masksToBounds == true)
        #expect(band.hitTest(CGPoint(x: 100, y: 18)) == nil)
    }

    /// The pane's toolbar places the band with each offer of the row, between the pane's content and its strip, at the
    /// band's frame in the pane, and hides it when the row is not shared (``PaneTabRowStandInHosting``).
    @Test func theToolbarPlacesTheBandUnderTheStripOverTheContentAndHidesItWithTheRow() throws {
        let pane = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let content = NSView(frame: pane.bounds)
        let strip = TabStripView(model: TabStripModel())
        let toolbar = PaneToolbarView(frame: .zero)
        pane.addSubview(content)
        pane.addSubview(strip)
        pane.addSubview(toolbar, positioned: .above, relativeTo: strip)
        toolbar.strip = strip
        let fill = CGColor(gray: 0.5, alpha: 1)
        toolbar.placeTabRowStandIn(PaneTabRowStandIn(frame: CGRect(x: 300, y: 264, width: 240, height: 36), rim: 1, tools: Self.tools, fill: fill),
                                   from: content)
        let band = try #require(pane.subviews.compactMap { $0 as? PaneTabRowStandInView }.first)
        #expect(!band.isHidden)
        #expect(band.frame == pane.convert(CGRect(x: 300, y: 264, width: 240, height: 36), from: content))
        let order = pane.subviews
        #expect(order.firstIndex(of: content)! < order.firstIndex(of: band)!)
        #expect(order.firstIndex(of: band)! < order.firstIndex(of: strip)!)
        toolbar.paintTabRowHole(nil)
        #expect(band.isHidden, "the band stayed with no row shared")
        toolbar.placeTabRowStandIn(PaneTabRowStandIn(frame: CGRect(x: 280, y: 264, width: 260, height: 36), rim: 1, tools: Self.tools, fill: fill),
                                   from: content)
        #expect(!band.isHidden)
        #expect(pane.subviews.filter { $0 is PaneTabRowStandInView }.count == 1, "a second band was made")
    }
}
