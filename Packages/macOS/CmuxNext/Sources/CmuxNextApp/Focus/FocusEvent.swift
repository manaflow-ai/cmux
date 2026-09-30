/// Inputs to the focus state machine (plans/cmux-next/focus.md section 4).
/// Every entrypoint that changes focus sends one of these to its window's
/// `FocusCoordinator`; nothing else writes focus.
nonisolated enum FocusEvent: Hashable, Sendable, Codable {
    enum Source: String, Hashable, Sendable, Codable {
        case mouse
        case keyboard
        case cli
        case palette
        /// App-driven (daemon echo, repair). Not a user intent.
        case programmatic

        var isUserIntent: Bool { self != .programmatic }
    }

    /// The first responder AppKit actually chose, classified.
    enum Responder: Hashable, Sendable, Codable {
        case content(pane: String)
        case addressBar(pane: String)
        case findBar(pane: String)
        /// A page's docked DevTools window became key.
        case devTools(pane: String)
        case sidebar
        case sidebarField
        case textField
        /// The window itself or nothing: usually a view left the window.
        case windowOrNone
    }

    enum DragOutcome: Hashable, Sendable, Codable {
        case cancelled
        /// The tabs land in this window; the first one takes focus once it
        /// is in a pane other than `awayFrom` (the source pane of a
        /// cross-pane move; nil for a reorder in place).
        case dropped(tabs: [String], awayFrom: String? = nil)
        /// The tabs left this window (the drop window focuses them).
        case movedAway
    }

    /// Daemon delta, workspace switch, selection or content change.
    case topology(FocusTopology)
    /// Mouse down in a pane, keyboard navigation, CLI, palette. A
    /// `workspace` other than the shown one is remembered for when it shows.
    case focusPane(String, workspace: String? = nil, source: Source)
    case selectTab(pane: String, tab: String, workspace: String? = nil, source: Source)
    /// Cmd-L, find in page, sidebar search.
    case focusTarget(FocusState.Target, source: Source)
    case responder(Responder, source: Source)
    case windowKey(Bool)
    case appActive(Bool)
    case overlayOpened(FocusState.Overlay)
    case overlayClosed(FocusState.Overlay)
    /// Starts a user intent that lands later (bumps the generation).
    case beginIntent
    /// Focus `key` once it exists, if no newer intent happened since
    /// `generation`.
    case expect(FocusState.Expectation.Key, target: FocusState.Target, generation: UInt64)
    case dragBegan(tabs: [String], pane: String)
    case dragEnded(DragOutcome)
    /// A pane's selected content view now exists (frame-deferred show).
    case contentPresented(pane: String)
    /// Nil toggles the focused page.
    case toggleBrowserFocusMode(tab: String?)
    /// The window's sidebar was shown or hidden. Hiding it while it (or
    /// its rename field) has the keyboard returns focus to the content.
    case sidebarVisibility(hidden: Bool)
}

/// Outputs of the reducer, applied by `FocusEffectApplier` after the
/// reducer returns. Each is idempotent.
nonisolated enum FocusEffect: Hashable, Sendable {
    /// Make `tab` the selected tab of `pane` (client-local selection).
    case select(pane: String, tab: String)
    /// Mirror the focused pane into `LayoutModel` (ring, column reveal)
    /// without emitting a layout intent.
    case revealPane(String)
    /// Make AppKit, WebKit and CEF match the resolved target.
    case moveResponder(FocusState.Resolved)
    case publishContext(FocusState.Context)
    case browserFocusMode(tab: String, active: Bool)
}
