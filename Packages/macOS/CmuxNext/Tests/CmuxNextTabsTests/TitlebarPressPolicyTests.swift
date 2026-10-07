import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextTabs

/// Dogfood nxdog14: "dragging top tabbar still sometimes move window
/// around". One owner decides whether a press in the titlebar band moves
/// the window (`TitlebarDragPolicy`): AppKit's own titlebar drag region is
/// empty (a band-wide blocker), so the window server never moves the window
/// on its own, and the policy says `.movesWindow` only for empty strip
/// space in the top row. Every point a tab drag can start from stays put.
@MainActor @Suite(.serialized) struct TitlebarPressPolicyTests {
    final class Harness {
        let window: NSWindow
        let root: NSView
        let model: TabStripModel
        let strip: TabStripView
        let blocker = TitlebarDragBlocker(frame: .zero)

        init(titles: [String], stripY: CGFloat? = nil) {
            let tabs = titles.enumerated().map { TabItem(id: TabID("t\($0.offset)"), title: $0.element) }
            model = TabStripModel(tabs: tabs, selectedID: tabs.first?.id)
            strip = TabStripView(model: model)
            window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 900, height: 400),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
            window.contentView = root
            strip.frame = NSRect(x: 100, y: stripY ?? 400 - TabStripView.preferredHeight, width: 800, height: TabStripView.preferredHeight)
            root.addSubview(strip)
            root.addSubview(blocker)
            TitlebarDragPolicy.layoutBandBlocker(blocker, in: root)
            strip.sync(fromModel: true)
            strip.layoutSubtreeIfNeeded()
            strip.relayout(animated: false)
        }

        func windowPoint(stripX x: CGFloat, y: CGFloat? = nil) -> CGPoint {
            strip.convert(CGPoint(x: x, y: y ?? strip.bounds.midY), to: nil)
        }

        func tabFrame(_ index: Int) -> CGRect {
            strip.tabsClip.convert(strip.cells[TabID("t\(index)")]!.frame, to: strip)
        }

        func decide(_ point: CGPoint) -> TitlebarPress { TitlebarDragPolicy.decide(at: point, in: window) }

        func close() { window.close() }
    }

    @Test func theWindowServerNeverMovesTheWindowFromTheBand() throws {
        let pin = StripHeightPin()
        defer { pin.restore() }
        let h = Harness(titles: ["One", "Two"])
        defer { h.close() }
        let band = TitlebarDragPolicy.bandRect(in: h.window)
        #expect(band.height >= TabStripView.preferredHeight - 0.5)
        let region = try #require(AppKitTitlebarDragRegion(window: h.window))
        for x in stride(from: CGFloat(1), to: band.width, by: 4) {
            for y in [band.minY + 1, band.midY, band.maxY - 1] {
                #expect(region.blocksWindowDrag(at: CGPoint(x: x, y: y)), "AppKit would move the window from (\(x), \(y))")
            }
        }
    }

    /// Every point of every tab (body, title, leading and trailing edge, top
    /// and bottom edge, close button), the gaps between tabs and +.
    @Test func noPointATabDragCanStartFromMovesTheWindow() {
        let h = Harness(titles: ["One", "Two", "Three"])
        defer { h.close() }
        let height = h.strip.bounds.height
        var points: [(String, CGPoint)] = []
        for index in 0..<3 {
            let tab = h.tabFrame(index)
            points += [("tab \(index) body", h.windowPoint(stripX: tab.midX)),
                       ("tab \(index) title", h.windowPoint(stripX: tab.minX + 30)),
                       ("tab \(index) leading edge", h.windowPoint(stripX: tab.minX + 0.5)),
                       ("tab \(index) trailing edge", h.windowPoint(stripX: tab.maxX - 0.5)),
                       ("tab \(index) top edge", h.windowPoint(stripX: tab.midX, y: 0.5)),
                       ("tab \(index) bottom edge", h.windowPoint(stripX: tab.midX, y: height - 0.5))]
            if index > 0 { points.append(("gap before tab \(index)", h.windowPoint(stripX: tab.minX))) }
            if let close = h.strip.cells[TabID("t\(index)")]?.closeButtonRect {
                let inStrip = h.strip.tabsClip.convert(CGPoint(x: h.strip.cells[TabID("t\(index)")]!.frame.minX + close.midX, y: 0), to: h.strip)
                points.append(("tab \(index) close", h.windowPoint(stripX: inStrip.x)))
            }
        }
        let plus = h.strip.contentView.convert(h.strip.newTabButton.frame, to: h.strip)
        points += [("+", h.windowPoint(stripX: plus.midX)), ("+ leading edge", h.windowPoint(stripX: plus.minX + 0.5))]
        for (name, point) in points {
            #expect(h.decide(point) == .staysPut, "\(name) moves the window")
        }
    }

    @Test func emptyStripSpaceInTheTopRowMovesTheWindow() {
        let h = Harness(titles: ["One"])
        defer { h.close() }
        let plus = h.strip.contentView.convert(h.strip.newTabButton.frame, to: h.strip)
        #expect(h.decide(h.windowPoint(stripX: (plus.maxX + h.strip.bounds.maxX) / 2)) == .movesWindow)
    }

    /// The app's layout pads panes by 2 pt, so a top-row strip starts 2 pt
    /// below the window's top edge (tagged build tdrag2: strip y 2..30 in a
    /// 32 pt band). It is still the titlebar row.
    @Test func aPaddedTopRowStripStillMovesTheWindowFromEmptySpace() {
        let h = Harness(titles: ["One"], stripY: 400 - TabStripView.preferredHeight - 2)
        defer { h.close() }
        let plus = h.strip.contentView.convert(h.strip.newTabButton.frame, to: h.strip)
        #expect(h.decide(h.windowPoint(stripX: (plus.maxX + h.strip.bounds.maxX) / 2)) == .movesWindow)
        #expect(h.decide(h.windowPoint(stripX: h.tabFrame(0).midX)) == .staysPut)
    }

    @Test func aStripBelowTheTopRowNeverMovesTheWindow() {
        let h = Harness(titles: ["One"], stripY: 200)
        defer { h.close() }
        let plus = h.strip.contentView.convert(h.strip.newTabButton.frame, to: h.strip)
        #expect(h.decide(h.windowPoint(stripX: (plus.maxX + h.strip.bounds.maxX) / 2)) == .staysPut)
    }
}

/// Pins compact density and no strip-height override for one synchronous
/// test. The titlebar band is the 32 pt system titlebar, so these checks hold
/// only at the default strip height; DensityTests, running in parallel, can
/// leave `.comfortable` or an override set across a suspension.
@MainActor struct StripHeightPin {
    private let density = DesignSettings.shared.density
    private let stripHeight = DesignSettings.shared.overrides[.tabStripHeight]

    init() {
        DesignSettings.shared.density = .compact
        DesignSettings.shared.setOverride(.tabStripHeight, nil)
    }

    func restore() {
        DesignSettings.shared.density = density
        DesignSettings.shared.setOverride(.tabStripHeight, stripHeight)
    }
}
