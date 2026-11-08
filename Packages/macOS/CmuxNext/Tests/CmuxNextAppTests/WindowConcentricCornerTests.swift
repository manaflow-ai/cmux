import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDesign
import CmuxNextSettings
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// Lawrence 2026-11-07, on a shot of the window's top-right corner: "we are not concentric with macos
/// window, we need to from first principles, make it all concentric with macos windows by default (but
/// still configurable)"; then "concentricity padding on top of tabbar is bad" and, of the ⋮ there,
/// "needs to be concentric (related to window concentricity)".
///
/// A card inset from a rounded window reads as part of it only when the two corners share a center:
/// the card's radius is the window's less the inset, and the inset is the same on both sides of the
/// corner. The 8 pt main pane 6 pt inside the 16 pt window (concentric: 10 pt) left a gap that widened
/// toward the corner, and its top sat 4 pt down against 6 pt at the side.
@MainActor @Suite(.serialized, .closesItsWindows) struct WindowConcentricCornerTests {
    private func load(radius: Double? = nil) {
        var layout: [String: JSONValue] = [:]
        if let radius { layout["paneCornerRadius"] = .number(radius) }
        // The curved main pane (the `card` style): the card a window corner holds.
        let snapshot = CmuxConfigSnapshot.parse(.object(["appearance": .object(["chromeStyle": .string(ChromeStyle.card.rawValue)]),
                                                         "layout": .object(layout)]),
                                                validDensities: SettingsApplier.validDensities, validMetrics: SettingsApplier.validMetrics)
        _ = SettingsApplier(registry: ActionRegistry.standard()).apply(snapshot)
        DesignSettings.shared.density = .compact
    }

    /// AppKit's titled-window corner per macOS major: 16 pt from macOS 26, 10 pt before.
    @Test(arguments: [(14, 10.0), (15, 10.0), (26, 16.0), (27, 16.0)])
    func theWindowRadiusFollowsTheMacOSVersion(major: Int, radius: Double) {
        #expect(Metrics.standardWindowCornerRadius(macOSMajor: major) == CGFloat(radius))
    }

    /// The running Mac's fallback matches what AppKit reports for a titled window here.
    @Test func theFallbackIsWhatAppKitDraws() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        #expect(window.frameCornerRadius == Metrics.standardWindowCornerRadius)
    }

    /// The pure rule: the window's radius less the inset; a square (fullscreen) window keeps the
    /// titled one's; a set radius wins, at most the window's.
    @Test(arguments: [(16.0, 6.0, nil, 10.0), (10.0, 6.0, nil, 4.0), (26.0, 6.0, nil, 20.0), (16.0, 20.0, nil, 0.0),
                      (16.0, 6.0, 12.0, 12.0), (16.0, 6.0, 20.0, 16.0), (0.0, 6.0, 12.0, 12.0)] as [(Double, Double, Double?, Double)])
    func aCardIsTheWindowRadiusLessItsInset(window: Double, inset: Double, setting: Double?, expected: Double) {
        let radius = Metrics.windowConcentricCornerRadius(windowCornerRadius: window, edgeInset: inset, setting: setting.map { CGFloat($0) })
        #expect(radius == CGFloat(expected), "\(window) pt window, \(inset) pt inset, setting \(String(describing: setting))")
        let square = Metrics.windowConcentricCornerRadius(windowCornerRadius: 0, edgeInset: inset, setting: nil)
        #expect(square == max(0, Metrics.standardWindowCornerRadius - CGFloat(inset)), "fullscreen keeps the windowed radius")
    }

    /// By default the curved main pane is concentric with the window across the gutter, whatever the
    /// window's radius; `layout.paneCornerRadius` still sets it.
    @Test(arguments: [10.0, 16.0, 26.0])
    func theMainPaneIsConcentricWithTheWindow(window: Double) {
        defer { load() }
        load()
        let gutter = Metrics.mainPaneGutter
        #expect(gutter > 0, "the default card has a gutter")
        #expect(Metrics.mainPaneCornerRadius(windowCornerRadius: CGFloat(window)) == max(0, CGFloat(window) - gutter),
                "a \(window) pt window, \(gutter) pt gutter")
        load(radius: 12)
        #expect(Metrics.mainPaneCornerRadius(windowCornerRadius: CGFloat(window)) == min(12, CGFloat(window)), "the setting wins")
    }

    /// The tabs nest in that card: its radius less their inset, so the first pill, the card and the
    /// window share one center.
    @Test func theTabsNestInTheWindowConcentricCard() {
        defer { load() }
        load()
        let card = Metrics.standardWindowCornerRadius - Metrics.mainPaneGutter
        #expect(Metrics.tabStripCardRadius == card)
        #expect(Metrics.tabCornerRadius == min(max(0, card - Metrics.tabStripCardInset), Metrics.tabHeight / 2))
    }

    /// The ⋮ in the card's top-trailing corner is concentric with it: the card's radius less the
    /// button's inset (it was the 4 pt item radius).
    @Test func theMoreButtonIsConcentricWithItsCorner() {
        defer { load() }
        load()
        let card = Metrics.standardWindowCornerRadius - Metrics.mainPaneGutter
        let inset = PaneToolbarView.trailingGap
        let side = TitlebarBandButton.side
        #expect(PaneToolbarView.moreCornerRadius(inset: inset) == min(max(0, card - inset), side / 2))
        let toolbar = PaneToolbarView(frame: NSRect(x: 0, y: 0, width: 160, height: Metrics.tabStripHeight))
        toolbar.moreButton.hoverStyle = .plate
        toolbar.show([], more: true, lit: false)
        toolbar.layoutSubtreeIfNeeded()
        toolbar.moreButton.updateLayer()
        #expect(toolbar.moreButton.layer?.cornerRadius == min(max(0, card - inset), side / 2))
    }

    /// The default top row keeps the gutter at the card's top as at its sides (an even inset), and
    /// the controls center on the pills' line there.
    @Test func theCardsTopInsetEqualsItsSideInset() throws {
        defer { load() }
        load()
        #expect(TopRowLineLook.tunable.defaultValue == .concentric)
        let design = DesignSettings.shared
        let before = (design.tabBarPosition, design.titlebar)
        design.tabBarPosition = .top
        design.titlebar = .minimal
        defer { (design.tabBarPosition, design.titlebar) = before }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 640))
        window.contentView = root
        let gutter = Metrics.mainPaneGutter
        let side = Metrics.windowEdgeInset(gutter, in: window)
        let top = WindowTitlebar.cardTopInset(of: root, minimal: true, gutter: gutter)
        #expect(top == side, "the card is \(top) pt below the window's top, \(side) pt from its side")
        let line = try #require(WindowTitlebar.topRowLine(in: window, look: .concentric))
        #expect(line.centerY == side + TopRowLine.tabsCenterY(.current, scale: window.backingScaleFactor),
                "the controls center on the pills, which sit in their strip as in every row")
    }
}
