import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSettings
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// The first tab sits as far in from the pane's leading edge as from its top edge, so it rests
/// evenly in the rounded corner (Lawrence 2026-10-19, on Floating Panes: "the first tab, we need
/// the same padding on the end and top. Think of all the other window variants and apply the same
/// thing"). Both gaps are measured from the edge the eye reads: under Floating Panes the pane
/// card's own edges, elsewhere the pane cell's edges. One exception keeps the 2026-10-01 rule:
/// where each pane is outlined (Panes, Card Outlined), the first tab starts on the outline's left
/// line, the line drawn right under it. The trailing end follows the same rule: the "…" button
/// keeps as much room to the trailing edge as above it.
@MainActor @Suite(.serialized, .closesItsWindows) struct PaneChromeEvenInsetTests {
    private func load(_ style: ChromeStyle?, density: Density) {
        let appearance: JSONValue = style.map { .object(["chromeStyle": .string($0.rawValue)]) } ?? .object([:])
        let snapshot = CmuxConfigSnapshot.parse(.object(["appearance": appearance]), validDensities: SettingsApplier.validDensities,
                                                validMetrics: SettingsApplier.validMetrics)
        _ = SettingsApplier(registry: ActionRegistry.standard()).apply(snapshot)
        DesignSettings.shared.density = density
    }

    private func reset() {
        load(nil, density: .compact)
    }

    private func window(_ size: CGSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func topLeft(_ rect: CGRect, in view: NSView, window: NSWindow) -> CGRect {
        let inWindow = view.convert(rect, to: nil)
        let height = window.contentView?.bounds.height ?? window.frame.height
        return CGRect(x: inWindow.minX, y: height - inWindow.maxY, width: inWindow.width, height: inWindow.height)
    }

    nonisolated static let variants: [(ChromeStyle, Density)] = ChromeStyle.allCases.flatMap { style in Density.allCases.map { (style, $0) } }

    @Test(arguments: variants)
    func theFirstTabSitsAsFarFromTheLeadingEdgeAsFromTheTop(style: ChromeStyle, density: Density) throws {
        defer { reset() }
        load(style, density: density)
        let model = TabStripModel(tabs: (0..<2).map { TabItem(id: TabID("tab\($0)"), title: "Tab \($0)") }, selectedID: TabID("tab0"))
        let strip = TabStripView(model: model)
        strip.dragsWindowFromEmptySpace = false
        let size = CGSize(width: 700, height: 200)
        let window = window(size)
        defer { window.close() }
        let scale = window.backingScaleFactor
        let stripHeight = PaneChromeMetrics.current.resolvedStripHeight(scale: scale)
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = host
        let padding = Metrics.panePadding
        strip.frame = NSRect(x: padding, y: size.height - padding - stripHeight, width: size.width - 2 * padding, height: stripHeight)
        host.addSubview(strip)
        strip.layoutSubtreeIfNeeded()
        let pill = topLeft(try #require(strip.firstTabPillFrame), in: strip, window: window)
        let stripRect = topLeft(strip.bounds, in: strip, window: window)
        if Metrics.paneBorder != .none {
            #expect(abs(pill.minX - stripRect.minX) <= 0.01, "\(style) \(density): the first tab starts \(pill.minX - stripRect.minX) pt off the outline")
            return
        }
        // Floating Panes: the card is the content rect; elsewhere the cell is the edge.
        let visible = Metrics.floatingPanes ? stripRect.minX : 0
        let visibleTop = Metrics.floatingPanes ? stripRect.minY : 0
        let leading = pill.minX - visible, top = pill.minY - visibleTop
        #expect(top > 0, "\(style) \(density): the tab touches the top edge")
        #expect(abs(leading - top) <= 0.01, "\(style) \(density): \(leading) pt before the first tab, \(top) pt above it")
    }

    @Test(arguments: Density.allCases)
    func theMoreButtonKeepsAsMuchRoomToTheTrailingEdgeAsAboveIt(density: Density) {
        defer { reset() }
        load(.floating, density: density)
        let toolbar = PaneToolbarView(frame: NSRect(x: 0, y: 0, width: 120, height: PaneChromeMetrics.current.resolvedStripHeight(scale: 2)))
        toolbar.show(more: true, lit: false)
        toolbar.layoutSubtreeIfNeeded()
        // The fixed trailing slot, at rest and throughout the hover fade.
        let more = toolbar.moreFrame()
        let trailing = toolbar.bounds.maxX - more.maxX, top = more.minY
        #expect(top > 0)
        #expect(abs(trailing - top) <= 0.01, "\(density): \(trailing) pt after \"…\", \(top) pt above it")
    }
}
