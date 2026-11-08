import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
import CmuxNextSettings
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// Lawrence 2026-11-05: "i think default roundness is too round now btw" / "maybe default roundness
/// should be omnibar roundness" / "sidebar workspaces is too rounded now" / "workspace roundness needs
/// to be same as tabs roundness".
///
/// Unset, the one corner radius (`layout.paneCornerRadius`) is the omnibar's 8 pt, and the omnibar
/// keeps that radius: the default is the omnibar's corner, not a rounder one the omnibar nests in.
/// A sidebar workspace row (and the pinned rows and group headers that share its fill) has the tab
/// pill's radius at every setting: one token, read by both.
@MainActor @Suite(.serialized, .closesItsWindows) struct DefaultCornerRadiusTests {
    private func load(radius: Double?, padding: Double?, style: ChromeStyle? = nil, density: Density = .compact) {
        var layout: [String: JSONValue] = [:]
        if let radius { layout["paneCornerRadius"] = .number(radius) }
        if let padding { layout["cornerPadding"] = .number(padding) }
        let appearance: JSONValue = style.map { .object(["chromeStyle": .string($0.rawValue)]) } ?? .object([:])
        let snapshot = CmuxConfigSnapshot.parse(.object(["appearance": appearance, "layout": .object(layout)]),
                                                validDensities: SettingsApplier.validDensities, validMetrics: SettingsApplier.validMetrics)
        _ = SettingsApplier(registry: ActionRegistry.standard()).apply(snapshot)
        DesignSettings.shared.density = density
    }

    private func reset() { load(radius: nil, padding: nil) }

    /// The omnibar's radius before the one-radius rule (a fixed 8 pt bar, Helium's tab corner).
    static let omnibarRadius: CGFloat = 8

    /// Unset, in every density, the one corner radius is the omnibar's, and the omnibar draws it.
    @Test(arguments: Density.allCases)
    func theDefaultRadiusIsTheOmnibars(density: Density) {
        defer { reset() }
        load(radius: nil, padding: nil, density: density)
        #expect(Metrics.cornerRadius == Self.omnibarRadius, "\(density): the default radius is \(Metrics.cornerRadius) pt")
        #expect(OmnibarStyle.barCornerRadius == Metrics.cornerRadius,
                "\(density): the omnibar is \(OmnibarStyle.barCornerRadius) pt, the default radius \(Metrics.cornerRadius) pt")
        #expect(OmnibarGlassLook.standard.resolvedCornerRadius(barHeight: OmnibarStyle.barHeight) == Self.omnibarRadius)
    }

    /// A set radius moves the omnibar with it.
    @Test(arguments: [6.0, 12.0])
    func theOmnibarFollowsTheSetRadius(radius: Double) {
        defer { reset() }
        load(radius: radius, padding: nil)
        #expect(OmnibarStyle.barCornerRadius == CGFloat(radius))
    }

    nonisolated static let cases: [(ChromeStyle, Double?, Double?)] =
        ChromeStyle.allCases.flatMap { style in [(nil, nil), (10, 2), (14, 4), (6, 1)].map { (style, $0.0, $0.1) } }

    /// A sidebar workspace row's corner is the tab pill's corner, at the default and at any set
    /// radius and padding, in every window style: the row token and the radius the real strip draws.
    @Test(arguments: cases)
    func aWorkspaceRowIsAsRoundAsATab(style: ChromeStyle, radius: Double?, padding: Double?) throws {
        defer { reset() }
        load(radius: radius, padding: padding, style: style)
        #expect(SidebarDensityTokens.rowCornerRadius == Metrics.tabCornerRadius,
                "\(style) \(String(describing: radius)): a row is \(SidebarDensityTokens.rowCornerRadius) pt, a tab \(Metrics.tabCornerRadius) pt")
        let scene = TabConcentricCornerTests.scene()
        defer { scene.window.close() }
        let cell = try #require(scene.firstCell)
        #expect(abs(cell.backgroundLayer.cornerRadius - SidebarDensityTokens.rowCornerRadius) <= 0.01,
                "\(style): the drawn tab is \(cell.backgroundLayer.cornerRadius) pt, a row \(SidebarDensityTokens.rowCornerRadius) pt")
    }
}
