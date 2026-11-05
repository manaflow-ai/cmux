import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
@testable import CmuxNextServer
import CmuxNextSettings
@testable import CmuxNextSidebar
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import Foundation
import Testing

/// Lawrence 2026-11-04: "all nested radius everywhere, for all types of panes where it applies, must be
/// concentric, where inner radius is outer minus padding, where padding is configurable too"; Chief
/// 2026-11-05: put glass, toasts, the new-tab page and every other fixed radius on the one rule.
///
/// Every rounded surface reads its corner from the one rule (`Metrics.corners`): a top-level surface
/// (a floating panel, popover, toast, dialog, card, banner) is the outer radius; a row or fill one
/// level in is the outer radius less the padding; a control two levels in, less twice the padding;
/// a row `inset` points inside a card is the card's radius less the inset. Each case loads a
/// cmux.json through the app's settings path and reads the radius the real surface draws with, so
/// a surface that keeps a fixed radius fails as soon as the setting moves.
@MainActor @Suite(.serialized, .closesItsWindows) struct ConcentricSurfaceCornerTests {
    private func load(radius: Double?, padding: Double?) {
        var layout: [String: JSONValue] = [:]
        if let radius { layout["paneCornerRadius"] = .number(radius) }
        if let padding { layout["cornerPadding"] = .number(padding) }
        let snapshot = CmuxConfigSnapshot.parse(.object(["layout": .object(layout)]),
                                                validDensities: SettingsApplier.validDensities, validMetrics: SettingsApplier.validMetrics)
        _ = SettingsApplier(registry: ActionRegistry.standard()).apply(snapshot)
        DesignSettings.shared.density = .compact
    }

    private func reset() { load(radius: nil, padding: nil) }

    nonisolated static let pairs: [(Double, Double)] = [(16, 3), (6, 1), (12, 4)]

    /// One radius rounds every top-level surface: floating glass panels, popovers, the neutral glass
    /// roles (cards, toasts, dialogs), the toast view, a card and a terminal banner.
    @Test(arguments: pairs)
    func everyTopLevelSurfaceIsTheOuterRadius(radius: Double, padding: Double) {
        defer { reset() }
        load(radius: radius, padding: padding)
        let outer = Metrics.corners.outer
        #expect(outer == CGFloat(radius))
        let surfaces: [(String, CGFloat)] = [
            ("Metrics.panelCornerRadius", Metrics.panelCornerRadius),
            ("PopupStyle.cornerRadius", PopupStyle.standard.cornerRadius),
            ("FloatingGlassStyle.toast", FloatingGlassStyle.toast.cornerRadius),
            ("FloatingGlassStyle.dialog", FloatingGlassStyle.dialog.cornerRadius),
            ("FloatingGlassStyle.card", FloatingGlassStyle.card.cornerRadius),
            ("CmuxToastView", CmuxToastView.cornerRadius),
            ("Glass.makeSurface(.toast)", Glass.makeSurface(.toast).cornerRadius),
            ("CardSurfaceView", CardSurfaceView().cornerRadius),
            ("TerminalStatusBanner", TerminalStatusBanner().layer?.cornerRadius ?? -1),
            ("ServerMetrics.cornerRadius", ServerMetrics.cornerRadius),
            ("OmnibarStyle.barCornerRadius", OmnibarStyle.barCornerRadius),
        ]
        for (name, value) in surfaces {
            #expect(value == outer, "\(radius)/\(padding): \(name) is \(value) pt, the one corner radius is \(outer) pt")
        }
    }

    /// A shape nested in a surface is concentric with it: one level in (a popover's row highlight, the
    /// omnibar inside the toolbar, a server card) is the radius less the padding, two levels in (an
    /// item, a tooltip) less twice the padding, and a popover row `padding` inside its card is the
    /// card's radius less that inset.
    @Test(arguments: pairs)
    func nestedShapesAreTheOuterRadiusLessThePadding(radius: Double, padding: Double) {
        defer { reset() }
        load(radius: radius, padding: padding)
        let corners = Metrics.corners
        let popup = PopupStyle.standard
        let nested: [(String, CGFloat, CGFloat)] = [
            ("PopupStyle.rowCornerRadius", popup.rowCornerRadius, max(0, popup.cornerRadius - popup.padding)),
            ("ServerMetrics.cardRadius", ServerMetrics.cardRadius, corners.inner),
            ("Metrics.itemCornerRadius", Metrics.itemCornerRadius, corners.radius(depth: 2)),
            ("TooltipPanel.radius", TooltipPanel.radius, corners.radius(depth: 2)),
            ("ServerMetrics.fieldRadius", ServerMetrics.fieldRadius, corners.radius(depth: 2)),
        ]
        for (name, value, expected) in nested {
            #expect(value == expected, "\(radius)/\(padding): \(name) is \(value) pt, concentric is \(expected) pt")
        }
    }

    /// Unset, the corners start from the omnibar's 8 pt (Lawrence 2026-11-05): 8 pt panels and
    /// cards, 4 pt items, and a popover row 4 pt inside its card.
    @Test func theDefaultsKeepTheCompactScale() {
        reset()
        #expect(Metrics.panelCornerRadius == 8)
        #expect(Metrics.itemCornerRadius == 4)
        #expect(FloatingGlassStyle.card.cornerRadius == 8)
        #expect(PopupStyle.standard.rowCornerRadius == PopupStyle.standard.cornerRadius - PopupStyle.standard.padding)
    }
}
