/// Sendable value projection of a key event that
/// ``AppMenuCoordinator/shouldSuppressStaleMenuShortcut(context:)`` branches on
/// to decide whether a stale built-in `cmux` menu key-equivalent (a default
/// shortcut the user has since remapped away) must be suppressed before AppKit's
/// menu machinery consumes the keystroke.
///
/// The app-side witness assembles every field: it owns the live `NSEvent`,
/// `KeyboardShortcutSettings.Action.allCases` evaluation, recorder-activity
/// reads, and the key-window/modal/sheet reads, then hands this pure value across
/// the ``AppMenuHosting`` seam so the boolean branching policy lives in the
/// coordinator while no AppKit type enters the package. The verdict is identical
/// to the legacy inline decision for every event.
public struct StaleMenuShortcutContext: Sendable {
    /// One `KeyboardShortcutSettings.Action` whose *default* shortcut matches the
    /// event (so it is a candidate stale built-in menu shortcut). The app-side
    /// witness only projects actions that satisfy the
    /// `isMenuBacked && matchesDefaultShortcut` filter, so membership in
    /// ``StaleMenuShortcutContext/staleDefaultActions`` already encodes
    /// `matchesStaleDefault`.
    public struct StaleDefaultAction: Sendable {
        /// Whether this action is a close-style action (the close-shortcut family
        /// is suppressed even when no current shortcut matches the event).
        public let isCloseAction: Bool

        /// Whether the action's *currently configured* shortcut matches the event
        /// (if so, the keystroke is a live shortcut, not a stale one, and must not
        /// be suppressed).
        public let currentShortcutMatchesEvent: Bool

        public init(isCloseAction: Bool, currentShortcutMatchesEvent: Bool) {
            self.isCloseAction = isCloseAction
            self.currentShortcutMatchesEvent = currentShortcutMatchesEvent
        }
    }

    /// Whether the event is a key-down (non-key events never suppress).
    public let isKeyDown: Bool

    /// Whether any shortcut recorder is armed (every keystroke must reach an
    /// active recorder, so suppression stands down, issue #5189).
    public let anyRecorderActive: Bool

    /// Whether the event targets a panel, a modal window, or a window with an
    /// attached sheet (those contexts own their own key handling).
    public let isPanelOrModalOrSheet: Bool

    /// Whether the event's device-independent modifier flags contain `.command`
    /// (built-in menu shortcuts are all command-based).
    public let hasCommandFlag: Bool

    /// The actions whose default shortcut matches the event (see
    /// ``StaleDefaultAction``). Empty when no built-in default matches.
    public let staleDefaultActions: [StaleDefaultAction]

    /// Whether *any* action's currently configured shortcut matches the event
    /// (the global escape hatch: a live binding always wins over suppression).
    public let anyCurrentShortcutMatchesEvent: Bool

    public init(
        isKeyDown: Bool,
        anyRecorderActive: Bool,
        isPanelOrModalOrSheet: Bool,
        hasCommandFlag: Bool,
        staleDefaultActions: [StaleDefaultAction],
        anyCurrentShortcutMatchesEvent: Bool
    ) {
        self.isKeyDown = isKeyDown
        self.anyRecorderActive = anyRecorderActive
        self.isPanelOrModalOrSheet = isPanelOrModalOrSheet
        self.hasCommandFlag = hasCommandFlag
        self.staleDefaultActions = staleDefaultActions
        self.anyCurrentShortcutMatchesEvent = anyCurrentShortcutMatchesEvent
    }
}
