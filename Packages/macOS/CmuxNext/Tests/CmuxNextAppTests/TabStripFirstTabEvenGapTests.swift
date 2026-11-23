import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSettings
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// Lawrence 2026-11-17, on a pinned image tab at the start of a pane's strip (Compact): "ensure top and left padding are
/// the same here". The first pill sat a fixed 4 pt from the strip's leading edge at every density (Lucas 2026-11-15)
/// while its top gap is the density's row gap (2.5 pt at Compact, 3 at Default), so the tab rested off-center in the
/// pane card's rounded corner. The end gap is now the pill's own top gap, on the screen's pixel grid: the same left and
/// top to the pixel at 1x and 2x, in every chrome style and density, and the + button keeps that one gap after the last
/// tab.
@MainActor @Suite(.serialized, .closesItsWindows) struct TabStripFirstTabEvenGapTests {
    private func load(_ style: ChromeStyle?, density: Density) {
        MainPaneGutterSuites.pinsCornerFlushOff(style != nil)
        let appearance: JSONValue = style.map { .object(["chromeStyle": .string($0.rawValue)]) } ?? .object([:])
        let snapshot = CmuxConfigSnapshot.parse(.object(["appearance": appearance]), validDensities: SettingsApplier.validDensities,
                                                validMetrics: SettingsApplier.validMetrics)
        _ = SettingsApplier(registry: ActionRegistry.standard()).apply(snapshot)
        DesignSettings.shared.density = density
    }

    nonisolated static let variants: [(ChromeStyle, Density)] = ChromeStyle.allCases.flatMap { style in Density.allCases.map { (style, $0) } }

    @Test(arguments: variants)
    func theFirstTabIsAsFarFromTheStripsLeadingEdgeAsFromItsTop(style: ChromeStyle, density: Density) throws {
        defer { load(nil, density: .compact) }
        load(style, density: density)
        // A pinned first tab (icon only) and the selected tab after it, as in the person's strip.
        let tabs = (0..<3).map { TabItem(id: TabID("tab\($0)"), title: "Tab \($0)", isPinned: $0 == 0) }
        let model = TabStripModel(tabs: tabs, selectedID: TabID("tab1"))
        let strip = TabStripView(model: model)
        strip.dragsWindowFromEmptySpace = false
        let size = CGSize(width: 700, height: 200)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scale = window.backingScaleFactor
        let stripHeight = PaneChromeMetrics.current.resolvedStripHeight(scale: scale)
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = host
        strip.frame = NSRect(x: 0, y: size.height - stripHeight, width: size.width, height: stripHeight)
        host.addSubview(strip)
        strip.layoutSubtreeIfNeeded()
        let pill = strip.convert(try #require(strip.firstTabPillFrame), to: nil)
        let edges = strip.convert(strip.bounds, to: nil)
        let left = pill.minX - edges.minX
        let top = edges.maxY - pill.maxY
        #expect(abs(left - top) <= 0.01, "\(style) \(density) @\(scale)x: the first tab is \(left) pt from the left, \(top) pt from the top")
        // Both on the pixel grid: a half-point gap at 1x would blur the pill's edge.
        #expect(abs((left * scale).rounded() - left * scale) <= 0.01, "\(style) \(density) @\(scale)x: left gap \(left) is off the pixel grid")
    }
}
