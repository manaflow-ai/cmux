/// The global input invariants (plans/cmux-next/input-spec.md): the model (F), transition (T) and
/// world (W) checks run in cmux-focus-core (`invariants`), over the app FFI's JSON channel
/// (`focus_input_step`, `focus_input_world`, `focus_debug_window`). The live monitor,
/// `debug.focus` and the journal replay call these, so a rule has one definition; none is in Swift.
/// Debug tooling only, never per event. The key routing checks (K) read the app's `KeyRouter` and
/// stay in the app (`InputInvariants+Routing.swift`).
public nonisolated struct InputInvariants: Sendable {
    public nonisolated init() {}

    public struct WorldResult: Hashable, Sendable, Codable {
        public var violations: [InputViolation]
        /// Windows skipped because content was still being presented.
        public var unsettled: [String]

        public init(violations: [InputViolation], unsettled: [String]) {
            self.violations = violations
            self.unsettled = unsettled
        }
    }

    // MARK: Model and transitions (F, T)

    private struct StepRequest: Encodable {
        var old: FocusState
        var event: FocusEvent
        var new: FocusState
        var window: String?
    }

    private struct StepResponse: Decodable {
        var violations: [InputViolation]
    }

    /// The model checks of `new` and the transition checks of `event` taking `old` to `new`. A
    /// refused call (an FFI wire mismatch) checked nothing: it fails loud in debug builds.
    public static func reduction(from old: FocusState, _ event: FocusEvent, to new: FocusState,
                                 window: String? = nil) -> [InputViolation] {
        let request = StepRequest(old: old, event: event, new: new, window: window)
        guard let response = FocusReducer.call("focus_input_step", request, as: StepResponse.self) else {
            assertionFailure("focus_input_step refused the reduction: nothing was checked")
            return []
        }
        return response.violations
    }

    // MARK: World (W)

    /// Every model and world check over `observation` (valid once effects and presentation
    /// settled; a window whose focused pane does not present the targeted tab yet is unsettled).
    /// A refused call (an FFI wire mismatch) checked nothing: every window is unsettled, and it
    /// fails loud in debug builds.
    public static func world(_ observation: InputObservation) -> WorldResult {
        guard let result = FocusReducer.call("focus_input_world", observation, as: WorldResult.self) else {
            assertionFailure("focus_input_world refused the observation: nothing was checked")
            return WorldResult(violations: [], unsettled: observation.windows.map(\.id))
        }
        return result
    }

    /// The responder AppKit should report for `resolved` (W1; `debug.focus` uses the same table);
    /// `childPage` names the tab whose Chromium page window has the keys. Nil when none is expected.
    public static func expectedResponder(_ resolved: FocusState.Resolved, childPage: String?) -> FocusEvent.Responder? {
        debugWindow(resolved, childPage: childPage, ghostty: [], ownTabs: [], isKey: false)?.expectedResponder
    }

    // MARK: debug.focus

    private struct DebugRequest: Encodable {
        var resolved: FocusState.Resolved
        var childPage: String?
        var ghostty: [String]
        var ownTabs: [String]
        var isKey: Bool
    }

    /// `debug.focus`'s checks of one window, by the machine's rules.
    public struct DebugWindow: Decodable, Sendable {
        /// The responder AppKit should report (W1, the monitor's own table); nil when none is
        /// expected (an empty pane, an overlay, no focus).
        public var expectedResponder: FocusEvent.Responder?
        /// The problem with the terminal tabs Ghostty reports focused; nil when they agree.
        public var ghosttyMismatch: String?
    }

    /// `debug.focus`'s checks for a window focused on `resolved`: `childPage` names the tab whose
    /// Chromium page window has the keys, `ghostty` the app-wide focused terminal tabs, `ownTabs`
    /// this window's tabs. Nil when the call failed (an FFI wire mismatch): it fails loud in debug builds.
    public static func debugWindow(_ resolved: FocusState.Resolved, childPage: String?, ghostty: [String],
                                   ownTabs: Set<String>, isKey: Bool) -> DebugWindow? {
        let request = DebugRequest(resolved: resolved, childPage: childPage, ghostty: ghostty, ownTabs: ownTabs.sorted(), isKey: isKey)
        guard let checks = FocusReducer.call("focus_debug_window", request, as: DebugWindow.self) else {
            assertionFailure("focus_debug_window refused the window: nothing was checked")
            return nil
        }
        return checks
    }
}
