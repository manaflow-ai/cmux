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
        #expect(PaneOverlayView.flashesFocus(wasFocused: false, focused: true, requested: true, ringShows: false))
    }

    @Test func noFlashWhenNotAskedStillFocusedOrRingShown() {
        #expect(!PaneOverlayView.flashesFocus(wasFocused: false, focused: true, requested: false, ringShows: false))
        #expect(!PaneOverlayView.flashesFocus(wasFocused: true, focused: true, requested: true, ringShows: false))
        #expect(!PaneOverlayView.flashesFocus(wasFocused: false, focused: false, requested: true, ringShows: false))
        #expect(!PaneOverlayView.flashesFocus(wasFocused: false, focused: true, requested: true, ringShows: true))
    }

    /// Only focus nobody clicked: a pointer, scroll or keyboard move already shows where it went.
    @Test func onlyAProgrammaticMoveAsksForTheFlash() {
        #expect(ScreenContentView.requestsFocusFlash(enabled: true, multiple: true, source: .programmatic, animated: true))
        for source: ColumnFocusSource in [.pointer, .scroll, .keyboard] {
            #expect(!ScreenContentView.requestsFocusFlash(enabled: true, multiple: true, source: source, animated: true))
        }
        #expect(!ScreenContentView.requestsFocusFlash(enabled: false, multiple: true, source: .programmatic, animated: true))
        #expect(!ScreenContentView.requestsFocusFlash(enabled: true, multiple: false, source: .programmatic, animated: true))
        #expect(!ScreenContentView.requestsFocusFlash(enabled: true, multiple: true, source: .programmatic, animated: false))
    }

    /// The pane after a close: the close takes the pane out and focuses its successor in one model
    /// change, which the screen sees as programmatic focus.
    @Test func theSuccessorOfAClosedPaneCountsAsProgrammatic() {
        let model = Self.threePanes()
        model.focus("b", source: .keyboard)
        _ = model.showPaneClose("b")
        #expect(model.focusedPane != "b")
        #expect(model.lastFocusSource == .programmatic)
    }

    /// A pane-navigation key marks its move as keyboard before the focus coordinator mirrors it
    /// back (programmatic by default): the mirror of the same pane keeps the keyboard source.
    @Test func aKeyMoveStaysKeyboardThroughTheCoordinatorMirror() {
        let model = Self.threePanes()
        model.focus("c", notify: false, source: .keyboard)
        model.focus("c", notify: false)
        #expect(model.lastFocusSource == .keyboard)
        #expect(!ScreenContentView.requestsFocusFlash(enabled: true, multiple: true, source: model.lastFocusSource, animated: true))
    }

    static func threePanes() -> LayoutModel {
        LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(
            .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("a"),
                   b: .split("y", axis: .vertical, ratio: 0.5, a: .leaf("b"), b: .leaf("c")))))],
            activeScreenID: "s", focusedPane: "a")
    }

    @Test func theFlashFadesOverAboutHalfASecond() throws {
        let fade = try #require(MotionFade(rawValue: "focusFlash"))
        #expect((0.4...0.6).contains(fade.baseDuration))
    }
}
