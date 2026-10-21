import AppKit
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Testing

/// `ui.calm` (``CalmMode``): cmux.json reaches the live motion gates, the hover card gate and the
/// hover fill, and turning it off gives back the user's own motion and hover card settings.
@MainActor @Suite(.serialized) struct CalmModeSettingTests {
    private func snapshot(_ ui: [String: JSONValue]) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(.object(["ui": .object(ui)]), validDensities: [], validMetrics: [])
    }

    /// Applies `ui` to the shared settings the gates read, runs `body`, then restores them.
    private func withShared(_ ui: [String: JSONValue], _ body: () -> Void) {
        let design = DesignSettings.shared
        let saved = (design.calmMode, design.animationsEnabled, design.hoverCardsEnabled, Motion.reduceMotionOverride)
        Motion.reduceMotionOverride = nil
        defer {
            design.calmMode = saved.0
            design.animationsEnabled = saved.1
            design.hoverCardsEnabled = saved.2
            Motion.reduceMotionOverride = saved.3
        }
        _ = SettingsApplier(design: design, registry: ActionRegistry()).apply(snapshot(ui))
        body()
    }

    @Test func offWhenCmuxJSONSaysNothing() {
        let parsed = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(parsed.calmMode == .off)
        #expect(parsed.diagnostics.isEmpty)
    }

    @Test func anUnknownValueIsOffPlusADiagnostic() {
        let parsed = snapshot(["calm": .bool(true)])
        #expect(parsed.calmMode == .off)
        #expect(parsed.diagnostics.map(\.path).contains("ui.calm"))
    }

    /// False on a host with Reduce Motion on already, where the motion checks would prove nothing.
    private var systemMovesFreely: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    @Test func calmReducesMotionAndStopsHoverCardsAndHoverFills() {
        guard systemMovesFreely else { return }
        withShared(["calm": .string("calm")]) {
            #expect(DesignSettings.shared.calmMode == .calm)
            #expect(Motion.reduceMotion)
            #expect(!Motion.sidebar.animatesMovement)
            #expect(!Motion.indicators.animatesLoops)
            // Fades stay (Reduce Motion keeps a short crossfade); hover feedback is instant.
            #expect(Motion.overlays.animatesFades)
            #expect(Motion.feedback.duration(.hover) == 0)
            #expect(!DesignSettings.shared.showsHoverCards)
            #expect(HoverCardCoordinator().hoverCardsEnabled() == false)
            #expect(ChromeHover.fillColor(.init(hovering: true)) == nil)
            #expect(ChromeHover.fillColor(.init(hovering: true, selected: true)) != nil)
            #expect(WebTheme.motionValue(Motion.web.policy) == "reduced")
        }
    }

    @Test func stillAlsoMakesEveryAnimationInstant() {
        withShared(["calm": .string("still")]) {
            #expect(!Motion.overlays.animatesFades)
            #expect(!Motion.tabs.animatesMovement)
            #expect(WebTheme.motionValue(Motion.web.policy) == "off")
            #expect(!DesignSettings.shared.showsHoverCards)
        }
    }

    @Test func offGivesBackTheUsersOwnSettings() {
        guard systemMovesFreely else { return }
        withShared(["calm": .string("still")]) {}
        withShared([:]) {
            #expect(DesignSettings.shared.calmMode == .off)
            #expect(!Motion.reduceMotion)
            #expect(Motion.overlays.animatesFades)
            #expect(DesignSettings.shared.showsHoverCards)
            #expect(ChromeHover.fillColor(.init(hovering: true)) != nil)
        }
    }

    @Test func settingsHasACalmModeRowInTheMotionGroup() {
        let row = SettingsSchema.descriptor(for: CalmModeSetting.configPath)
        let master = SettingsSchema.descriptor(for: MotionCategoriesSetting.enabledPath)
        #expect(row?.section == .appearance)
        #expect(row?.group == master?.group)
    }
}
