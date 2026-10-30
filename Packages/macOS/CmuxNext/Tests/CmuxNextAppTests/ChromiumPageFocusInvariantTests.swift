import CmuxNextFocus
import Testing
@testable import CmuxNextApp

/// A cmux page in Chromium (Keyboard Shortcuts, Debug Settings) shows in a child window and has
/// the keys there, like a Chromium browser tab (`FocusEffectApplier`). The live input monitor must
/// read that as in sync: no W1, chromium or W5 report while such a page is focused.
struct ChromiumPageFocusInvariantTests {
    private static let checked: Set<InputInvariant> = [.responderMatches, .chromiumMatches, .keyWindowOwned]

    /// One window focused on a page tab: in Chromium its page window has the keys and this window
    /// keeps no responder; in WebKit the page's view in the pane is first responder of a key window.
    private func observation(chromium: Bool) -> InputObservation {
        var model = FocusState()
        model.resolved = .page(pane: "pane_a", tab: "tab_keys")
        model.underlying = model.resolved
        model.windowKey = !chromium
        let window = InputObservation.Window(
            id: "window_1", model: model, responder: chromium ? .windowOrNone : .content(pane: "pane_a"),
            responderClass: nil, isKey: !chromium, layoutFocus: nil, ghosttyFocused: [],
            childPage: chromium ? "tab_keys" : nil, presented: ["pane_a": "tab_keys"],
            childWindowTabs: chromium ? ["tab_keys"] : [])
        return InputObservation(windows: [window], keyWindow: chromium ? .childPage(window: "window_1") : .window("window_1"),
                                paletteOpen: false, activeWindow: "window_1", context: FocusState.Context())
    }

    private func violations(_ observation: InputObservation) -> [InputViolation] {
        InputInvariants.world(observation).violations.filter { Self.checked.contains($0.invariant) }
    }

    @Test func aFocusedChromiumPageWithTheKeysIsInSync() {
        #expect(violations(observation(chromium: true)).isEmpty)
    }

    @Test func aFocusedWebKitPageWithTheResponderIsInSync() {
        #expect(violations(observation(chromium: false)).isEmpty)
    }
}
