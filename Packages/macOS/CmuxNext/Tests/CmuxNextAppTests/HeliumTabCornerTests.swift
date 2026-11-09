import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDesign
import CmuxNextSettings
@testable import CmuxNextTabs
import Testing

/// Lawrence 2026-10-31: "i dont like the new roundness of tabs, we need to match helium roundess,
/// and round the pane bg thing more". Helium 0.17.2.1 (Chromium 156), measured from its source:
///
/// - patches/helium/ui/tabs.patch: `TabStyle::GetTopCornerRadius` and `GetBottomCornerRadius` are
///   8, and every tab fill is one detached `SkRRect` (`if ((true))`), so a tab is a pill with four
///   8 pt circular corners and no bottom flare.
/// - patches/helium/ui/frame-radius-helper.patch: the content card's corner at the window is
///   `GetSystemWindowRadius() - kHeliumBasePadding`, 17 - 3 = 14 pt on macOS 26.
///
/// The tabs were 8 pt *continuous* corners (a squircle whose curve runs about 12 pt along each
/// edge, so on a 24 pt pill it reads rounder than Helium's 8 pt arc) in a 10 pt card.
@MainActor @Suite(.serialized, .closesItsWindows) struct HeliumTabCornerTests {
    private func load(_ style: ChromeStyle?, density: Density) {
        let appearance: JSONValue = style.map { .object(["chromeStyle": .string($0.rawValue)]) } ?? .object([:])
        let snapshot = CmuxConfigSnapshot.parse(.object(["appearance": appearance]), validDensities: SettingsApplier.validDensities,
                                                validMetrics: SettingsApplier.validMetrics)
        _ = SettingsApplier(registry: ActionRegistry.standard()).apply(snapshot)
        DesignSettings.shared.density = density
    }

    private func reset() { load(nil, density: .compact) }

    /// Every tab pill and the strip's + have Helium's circular corners, at every density. Their radius
    /// is the one concentric tab radius: Helium's 8 pt until Lawrence 2026-11-05 ("default roundness
    /// is too round now", "default roundness should be omnibar roundness") moved the outer default
    /// to the omnibar's 8 pt, so a tab nested the corner padding inside it is 6 pt.
    @Test(arguments: Density.allCases)
    func tabsHaveHeliumsCorners(density: Density) throws {
        defer { reset() }
        load(nil, density: density)
        let scene = TabConcentricCornerTests.scene()
        defer { scene.window.close() }
        for cell in scene.strip.cells.values {
            #expect(cell.backgroundLayer.cornerRadius == Metrics.tabCornerRadius, "\(density): \(cell.backgroundLayer.cornerRadius) pt")
            #expect(cell.backgroundLayer.cornerRadius < Metrics.heliumTabCornerRadius, "\(density): less round than the old 8 pt tab")
            #expect(cell.backgroundLayer.cornerCurve == .circular, "\(density): Helium's tab is a circular-arc SkRRect, not a squircle")
        }
    }

    // The pane card's 14 pt corner in a real window: `MainPaneWindowCornerTests`.
}
