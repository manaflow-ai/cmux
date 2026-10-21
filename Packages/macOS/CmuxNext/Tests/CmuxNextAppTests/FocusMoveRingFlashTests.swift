import CmuxNextDesign
@testable import CmuxNextLayout
import Testing

/// Leo, 2026-10-21: a link opened beside his chat moved focus without a click, and nothing showed
/// where it went. Behind a Debug toggle (off by default, for Leo to judge live), the focus ring
/// shows briefly on the pane focus moved to when nothing the person clicked moved it (a link open,
/// the pane after a close, an agent's handoff), then fades.
@MainActor @Suite struct FocusMoveRingFlashTests {
    @Test func theToggleIsOffByDefault() {
        #expect(FocusIndicatorTunables.flashOnMove.defaultValue == false)
    }

    @Test func aPaneFlashesWhenFocusArrivesWithoutAClick() {
        #expect(PaneOverlayView.flashesFocus(wasFocused: false, focused: true, requested: true, animated: true, ringShows: false))
    }

    @Test func noFlashWhenOffStillFocusedRingShownOrNotAnimated() {
        #expect(!PaneOverlayView.flashesFocus(wasFocused: false, focused: true, requested: false, animated: true, ringShows: false))
        #expect(!PaneOverlayView.flashesFocus(wasFocused: true, focused: true, requested: true, animated: true, ringShows: false))
        #expect(!PaneOverlayView.flashesFocus(wasFocused: false, focused: false, requested: true, animated: true, ringShows: false))
        #expect(!PaneOverlayView.flashesFocus(wasFocused: false, focused: true, requested: true, animated: true, ringShows: true))
        #expect(!PaneOverlayView.flashesFocus(wasFocused: false, focused: true, requested: true, animated: false, ringShows: false))
    }

    /// Only focus nobody clicked: a pointer, scroll or keyboard move already shows where it went.
    @Test func onlyAProgrammaticMoveAsksForTheFlash() {
        #expect(ScreenContentView.requestsFocusFlash(enabled: true, multiple: true, source: .programmatic))
        for source: ColumnFocusSource in [.pointer, .scroll, .keyboard] {
            #expect(!ScreenContentView.requestsFocusFlash(enabled: true, multiple: true, source: source))
        }
        #expect(!ScreenContentView.requestsFocusFlash(enabled: false, multiple: true, source: .programmatic))
        #expect(!ScreenContentView.requestsFocusFlash(enabled: true, multiple: false, source: .programmatic))
    }

    @Test func theFlashFadesOverAboutHalfASecond() throws {
        let fade = try #require(MotionFade(rawValue: "focusFlash"))
        #expect((0.4...0.6).contains(fade.baseDuration))
    }
}
