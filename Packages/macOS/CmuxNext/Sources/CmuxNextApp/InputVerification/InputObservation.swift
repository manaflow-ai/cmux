/// A snapshot of the combined input state: each window's focus model next
/// to what AppKit, Ghostty, WebKit and Chromium actually show
/// (plans/cmux-next/input-spec.md section 2). Built from the live app by
/// `InputObservationBuilder`, and from the simulated world by the model
/// fuzzer, so both are checked by the same `InputInvariants`.
nonisolated struct InputObservation: Hashable, Sendable, Codable {
    /// Which window has the keyboard at the AppKit level.
    enum KeyWindow: Hashable, Sendable, Codable {
        case none
        /// A cmux window itself.
        case window(String)
        /// A Chromium page window over cmux window `window`.
        case childPage(window: String)
        /// A panel over cmux window `window` (palette, group editor), or an
        /// app-wide panel when `window` is nil.
        case panel(window: String?, kind: String)
        case sheet(window: String)
        /// Settings, alerts, anything that is not over a cmux window.
        case other(String)
    }

    struct Window: Hashable, Sendable, Codable {
        var id: String
        var model: FocusState
        /// The first responder AppKit reports, classified.
        var responder: FocusEvent.Responder
        /// Class name of the first responder, for reports.
        var responderClass: String?
        var isKey: Bool
        /// `LayoutModel.focusedPane`.
        var layoutFocus: String?
        /// Tabs of this window whose Ghostty surface has focus.
        var ghosttyFocused: [String]
        /// The page the applier gave Chromium focus to.
        var childPage: String?
        /// The tab each pane shows right now (`currentTabKey`).
        var presented: [String: String]
        /// Tabs whose page lives in a child window (Chromium).
        var childWindowTabs: [String] = []
        /// A sheet is attached to the window.
        var hasSheet = false
    }

    var windows: [Window]
    var keyWindow: KeyWindow
    /// `paletteOpen` in the registry context.
    var paletteOpen: Bool
    /// The window that publishes the registry context.
    var activeWindow: String?
    /// The published `terminalFocused` / `browserFocused` bits.
    var context: FocusState.Context

    func window(_ id: String) -> Window? { windows.first { $0.id == id } }
}

/// One broken invariant.
nonisolated struct InputViolation: Hashable, Sendable, Codable {
    var invariant: InputInvariant
    var window: String?
    var detail: String

    /// Stable identity for de-duplication (details may carry ids that differ).
    var signature: String { "\(invariant.rawValue)@\(window ?? "-")" }
}

/// The invariants of plans/cmux-next/input-spec.md, by id.
nonisolated enum InputInvariant: String, Hashable, Sendable, Codable, CaseIterable {
    // Model (every state the reducers produce).
    case overlayOnTop = "F1"
    case livePane = "F2"
    case paneWhenPanes = "F3"
    case targetKind = "F4"
    case noStaleExpectation = "F5"
    case focusModeLive = "F6"
    case omnibarTarget = "F8"
    // Transitions.
    case noSteal = "T1"
    case passiveEvents = "T2"
    case monotonicGeneration = "T3"
    // Key routing.
    case systemTierAlways = "K1"
    case navigationTier = "K2"
    case contentTierGuarded = "K3"
    case menuMatchesRouter = "K4"
    // Attach.
    case inputOrder = "A1"
    case liveLinkOnly = "A2"
    case detachOnce = "A3"
    case closedIsFinal = "A4"
    // World (after settle).
    case responderMatches = "W1"
    case layoutMatches = "W2"
    case ghosttyMatches = "W3"
    case chromiumMatches = "W4"
    case keyWindowOwned = "W5"
    case overlaysMatch = "W6"
    case contextMatches = "W7"
    case presentedMatchesSelection = "W8"
    case presentationSettles = "W9"
    // Geometry (after settle).
    case chromiumGeometry = "G1"

    var summary: String {
        switch self {
        case .overlayOnTop: "an open overlay is the keyboard target"
        case .livePane: "focus names a pane and tab that exist and are selected"
        case .paneWhenPanes: "a window with panes has a focused pane"
        case .targetKind: "the target fits the selected tab's kind"
        case .noStaleExpectation: "no pending focus survives a newer user intent"
        case .focusModeLive: "browser focus mode only names live tabs"
        case .omnibarTarget: "omnibar editing implies the address bar target"
        case .noSteal: "an expectation from an older intent never moves focus"
        case .passiveEvents: "key, activation, presentation and overlay events never retarget"
        case .monotonicGeneration: "the intent generation never decreases"
        case .systemTierAlways: "tier 0 keys always reach the router"
        case .navigationTier: "tier 1 keys reach the router unless browser focus mode"
        case .contentTierGuarded: "tier 2 never runs in a text input or focus mode"
        case .menuMatchesRouter: "menu key equivalents follow the router"
        case .inputOrder: "attach input is neither lost, duplicated nor reordered"
        case .liveLinkOnly: "input goes only to the live link"
        case .detachOnce: "every opened link is detached exactly once"
        case .closedIsFinal: "a closed attachment sends nothing"
        case .responderMatches: "AppKit first responder matches the model target"
        case .layoutMatches: "layout focus matches the model pane"
        case .ghosttyMatches: "Ghostty focus is the model terminal in the key window only"
        case .chromiumMatches: "Chromium page focus matches the model"
        case .keyWindowOwned: "the key window belongs to the model target"
        case .overlaysMatch: "open palettes and sheets match the overlay stacks"
        case .contextMatches: "the window that owns the keyboard is active and its focus is the published context"
        case .presentedMatchesSelection: "every shown pane shows its selected tab, and that tab is in the pane"
        case .presentationSettles: "the focused pane presents the targeted tab within a settle"
        case .chromiumGeometry: "every Chromium page window covers its pane in screen coordinates (ChildPageGeometry)"
        }
    }
}
