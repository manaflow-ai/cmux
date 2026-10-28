import CmuxNextDesign
import Foundation
import Testing

/// p15-oracle-134: DesignSettings lives in CmuxNextAppearance, which knows no theme store, so a change
/// every theme payload reads (calm mode's hover fills, the terminal's face) is the
/// ``AppearanceSignals/Signal/themeRepaint`` signal, and the store the composition root hands the
/// signals to repaints on it (`ThemeStore.repaint(following:)`). Before the move the settings called
/// `ThemeScope.app.store.repaintAll()` themselves.
@MainActor @Suite struct ThemeRepaintSignalTests {
    @MainActor private final class Responder: ThemeResponsive {
        var repaints = 0
        func themeDidChange() { repaints += 1 }
    }

    @Test func calmModeAndTheTerminalFaceRepaintTheStoreThatFollowsTheSignals() {
        let design = DesignSettings(display: { AppearanceSignals.DisplayOptions() })
        let store = ThemeStore()
        let responder = Responder()
        store.addResponder(responder)
        store.repaint(following: design.signals)

        design.calmMode = .calm
        #expect(responder.repaints == 1, "calm mode turns hover fills off: every window and page repaints")
        design.calmMode = .calm
        #expect(responder.repaints == 1, "the same calm mode again changes nothing")

        design.terminalFontFamily = "Menlo"
        #expect(responder.repaints == 2, "pages that show code draw in the terminal's face")
        design.terminalConfigFontFamily = "Monaco"
        #expect(responder.repaints == 2, "cmux.json's face still wins: the face pages draw in did not change")

        design.hoverCardsEnabled = false
        design.animationSpeed = design.animationSpeed == .fast ? .normal : .fast
        #expect(responder.repaints == 2, "motion and hover-card changes do not repaint the theme")
        withExtendedLifetime(design) {}
    }

    @Test func theRepaintComesAfterTheSignalsOfTheSameChange() {
        let design = DesignSettings(display: { AppearanceSignals.DisplayOptions() })
        var heard: [AppearanceSignals.Signal] = []
        let watches = [AppearanceSignals.Signal.themeRepaint, .motion].map { signal in
            design.signals.subscribe([signal], owner: "\(signal)") { heard.append(signal) }
        }
        design.calmMode = .still
        #expect(heard == [.motion, .themeRepaint], "a repaint reads the motion values their subscribers already updated")
        withExtendedLifetime((design, watches)) {}
    }
}
