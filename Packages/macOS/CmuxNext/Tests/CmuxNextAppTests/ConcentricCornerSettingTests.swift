import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDesign
import CmuxNextSettings
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// Lawrence 2026-11-04: "i want radius of tabbar tabs to be configurable + radius of panes, both need
/// to be same setting, and all nested radius everywhere, for all types of panes where it applies,
/// must be concentric, where iner radius is outer minus padding, where padding is configurable too".
///
/// One outer radius (`layout.paneCornerRadius`) rounds the pane cards, the curved main pane and,
/// less the padding, the tab pills; one padding (`layout.cornerPadding`) is the real gap between a
/// card's edge and its first pill, so the nested corner shares the card's center. Each case loads a
/// cmux.json through the app's settings path and reads what the real strip draws.
@MainActor @Suite(.serialized, .closesItsWindows) struct ConcentricCornerSettingTests {
    private func load(radius: Double?, padding: Double?, style: ChromeStyle?, density: Density = .compact) {
        var layout: [String: JSONValue] = [:]
        if let radius { layout["paneCornerRadius"] = .number(radius) }
        if let padding { layout["cornerPadding"] = .number(padding) }
        let appearance: JSONValue = style.map { .object(["chromeStyle": .string($0.rawValue)]) } ?? .object([:])
        let snapshot = CmuxConfigSnapshot.parse(.object(["appearance": appearance, "layout": .object(layout)]),
                                                validDensities: SettingsApplier.validDensities, validMetrics: SettingsApplier.validMetrics)
        _ = SettingsApplier(registry: ActionRegistry.standard()).apply(snapshot)
        DesignSettings.shared.density = density
    }

    private func reset() { load(radius: nil, padding: nil, style: nil) }

    nonisolated static let pairs: [(Double, Double)] = [(10, 2), (6, 2), (14, 2), (14, 6), (12, 4), (16, 8), (8, 0)]
    nonisolated static let cases: [(ChromeStyle, Double, Double)] =
        [ChromeStyle.floating, .card].flatMap { style in pairs.map { (style, $0.0, $0.1) } }

    /// The first pill sits `padding` in from the card's top and leading edges, the card has the set
    /// radius, and the pill's radius is the radius less the padding (at most half the tab).
    @Test(arguments: cases)
    func theTabIsTheRadiusLessThePadding(style: ChromeStyle, radius: Double, padding: Double) throws {
        defer { reset() }
        load(radius: radius, padding: padding, style: style)
        let card = try #require(TabConcentricCornerTests.enclosingCardRadius(), "\(style): the strip sits in a rounded card")
        #expect(card == CGFloat(radius), "\(style): the card's radius is the one corner radius")
        let scene = TabConcentricCornerTests.scene()
        defer { scene.window.close() }
        let inset = scene.pill.minY - scene.card.minY
        #expect(abs(inset - CGFloat(padding)) <= 0.01, "\(style) \(radius)/\(padding): the pill is \(inset) pt below the card's top")
        #expect(abs((scene.pill.minX - scene.card.minX) - CGFloat(padding)) <= 0.01, "\(style): the same gap at the leading edge")
        // At Default the tab takes the workspace row's Codex corner instead (Metrics.tabRowCornerRadius, tabs follow rows).
        let expected = Metrics.tabRowCornerRadius ?? min(max(0, CGFloat(radius - padding)), Metrics.tabHeight / 2)
        for cell in scene.strip.cells.values {
            #expect(abs(cell.backgroundLayer.cornerRadius - expected) <= 0.01,
                    "\(style) \(radius)/\(padding): a tab is \(cell.backgroundLayer.cornerRadius) pt, concentric is \(expected) pt")
        }
    }

    /// One setting: the radius also rounds the curved main pane (at most the window's own corner),
    /// and setting it does not turn on pane borders.
    @Test(arguments: [6.0, 12.0, 20.0])
    func theRadiusIsTheMainPanesToo(radius: Double) {
        defer { reset() }
        load(radius: nil, padding: nil, style: .card)
        let separation = Metrics.paneSeparation
        load(radius: radius, padding: nil, style: .card)
        #expect(Metrics.mainPaneCornerRadius(windowCornerRadius: 16) == min(CGFloat(radius), 16))
        #expect(Metrics.paneSeparation == separation, "a radius alone keeps the window style's separation")
    }

    /// Fills inside a pill (the close button's hover) are concentric with the pill: its radius less
    /// the fill's inset from the pill's edge.
    @Test(arguments: [(10.0, 2.0), (14.0, 2.0), (6.0, 2.0)])
    func theCloseButtonIsConcentricWithItsTab(radius: Double, padding: Double) throws {
        defer { reset() }
        load(radius: radius, padding: padding, style: .floating)
        let scene = TabConcentricCornerTests.scene()
        defer { scene.window.close() }
        let cell = try #require(scene.strip.cells[TabID("tab0")])
        cell.isHovered = true // lays the cell out (`stateChanged`)
        let close = try #require(cell.closeBackgroundLayer, "the selected, hovered tab shows its x")
        let pill = cell.backgroundLayer.frame
        let inset = min(close.frame.minY - pill.minY, pill.maxY - close.frame.maxY)
        let expected = min(max(0, cell.backgroundLayer.cornerRadius - inset), close.frame.height / 2)
        #expect(abs(close.cornerRadius - expected) <= 0.01, "the x's fill is \(close.cornerRadius) pt \(inset) pt inside a \(cell.backgroundLayer.cornerRadius) pt tab")
    }
}
