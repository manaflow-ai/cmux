import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
import CmuxNextSettings
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// Lawrence 2026-11-12: "roundness of all buttons should match roundness of tabs/workspaces".
///
/// Every button corner is one token, `Metrics.buttonCornerRadius`, which is the tab pill's corner (the one sidebar
/// workspace rows share), at every density and corner setting. The test draws the real buttons (a dialog
/// button, a keyed dialog button, a browser toolbar and text button, a sidebar card button) and reads the
/// corner they drew. A button nested in a rounded shape stays concentric with it.
@MainActor @Suite(.serialized, .closesItsWindows) struct ButtonCornerRadiusTests {
    private func load(radius: Double?, padding: Double?, density: Density) {
        var layout: [String: JSONValue] = [:]
        if let radius { layout["paneCornerRadius"] = .number(radius) }
        if let padding { layout["cornerPadding"] = .number(padding) }
        let snapshot = CmuxConfigSnapshot.parse(.object(["appearance": .object([:]), "layout": .object(layout)]),
                                                validDensities: SettingsApplier.validDensities, validMetrics: SettingsApplier.validMetrics)
        _ = SettingsApplier(registry: ActionRegistry.standard()).apply(snapshot)
        DesignSettings.shared.density = density
    }

    private func reset() { load(radius: nil, padding: nil, density: .compact) }

    nonisolated static let cases: [(Density, Double?, Double?)] =
        Density.allCases.flatMap { density in [(nil, nil), (12, 4), (6, 1)].map { (density, $0.0, $0.1) } }

    @Test(arguments: cases)
    func everyButtonRoundsAsATab(density: Density, radius: Double?, padding: Double?) {
        defer { reset() }
        load(radius: radius, padding: padding, density: density)
        let tab = Metrics.tabCornerRadius
        let at = "\(density) \(String(describing: radius))"
        #expect(Metrics.buttonCornerRadius == tab, "\(at): a button is \(Metrics.buttonCornerRadius) pt, a tab \(tab) pt")
        #expect(SidebarDensityTokens.rowCornerRadius == tab, "\(at): a workspace row is not a tab's corner")

        // A dialog button and a keyed one, as drawn.
        for keycap in [false, true] {
            let button = CmuxDialogButtonView(.ok("Save"), hint: .return, keycap: keycap, target: nil, action: NSSelectorFromString("noop:"))
            button.frame = NSRect(x: 0, y: 0, width: 120, height: CmuxDialogMetrics.keycapButtonHeight)
            button.layoutSubtreeIfNeeded()
            #expect(button.layer?.cornerRadius == tab, "\(at): a dialog button (keycap \(keycap)) is \(String(describing: button.layer?.cornerRadius)) pt")
        }

        // The browser's toolbar and text buttons, as drawn.
        let toolbar = ChromeIconButton(icon: .navPreviousMatch, label: "Back", action: nil, target: nil, toolbar: true)
        toolbar.layoutSubtreeIfNeeded()
        #expect(toolbar.layer?.cornerRadius == tab, "\(at): the toolbar button is \(String(describing: toolbar.layer?.cornerRadius)) pt")
        let text = ChromeTextButton(title: "Allow", prominent: true, action: nil, target: nil)
        text.layoutSubtreeIfNeeded()
        #expect(text.layer?.cornerRadius == tab, "\(at): a browser text button is \(String(describing: text.layer?.cornerRadius)) pt")

        // A sidebar card's button.
        let card = SidebarCardTextButton(frame: NSRect(x: 0, y: 0, width: 80, height: 22))
        card.layout()
        #expect(card.layer?.cornerRadius == tab, "\(at): a sidebar card button is \(String(describing: card.layer?.cornerRadius)) pt")
    }

    /// A small round control never rounds past half its side, and a nested button stays concentric:
    /// its corner is the outer one less the inset.
    @Test func fittedAndNestedCornersFollowTheRule() {
        defer { reset() }
        load(radius: nil, padding: nil, density: .comfortable)
        let tab = Metrics.tabCornerRadius
        #expect(Metrics.buttonCornerRadius(fitting: CGSize(width: 40, height: 40)) == tab)
        #expect(Metrics.buttonCornerRadius(fitting: CGSize(width: 40, height: 6)) == min(tab, 3))
        #expect(Metrics.buttonCornerRadius(inset: 2) == max(0, tab - 2))
        #expect(Metrics.buttonCornerRadius(nestedIn: 12, inset: 4) == 8)
        #expect(Metrics.buttonCornerRadius(nestedIn: 3, inset: 5) == 0)
        // The dialog's keycap plate nests in its keyed button.
        #expect(CmuxDialogMetrics.keycapButtonCornerRadius == tab)
    }
}
