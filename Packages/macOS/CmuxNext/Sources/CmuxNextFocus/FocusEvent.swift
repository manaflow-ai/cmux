/// Inputs to the focus state machine (plans/cmux-next/focus.md section 4).
/// Sent to `FocusMachine` in its typed C form; the synthesized `Codable`
/// shape (`cmux-focus-core`'s `FocusEvent` JSON) is the input journal's.
/// Every entrypoint that changes focus sends one of these to its window's
/// `FocusCoordinator`; nothing else writes focus.
public nonisolated enum FocusEvent: Hashable, Sendable, Codable {
    public enum Source: String, Hashable, Sendable, Codable {
        case mouse
        case keyboard
        case cli
        case palette
        /// App-driven (daemon echo, repair). Not a user intent.
        case programmatic

        public var isUserIntent: Bool { self != .programmatic }
    }

    /// The first responder AppKit actually chose, classified.
    public enum Responder: Hashable, Sendable, Codable {
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

    public enum DragOutcome: Hashable, Sendable, Codable {
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
    /// `generation`. `awayFrom`: land only once the tab is in another pane
    /// (a tab opened in one pane and then moved into a new split).
    case expect(FocusState.Expectation.Key, target: FocusState.Target, awayFrom: String? = nil, generation: UInt64)
    case dragBegan(tabs: [String], pane: String)
    case dragEnded(DragOutcome)
    /// A pane's selected content view now exists (frame-deferred show).
    case contentPresented(pane: String)
    /// Nil toggles the focused page.
    case toggleBrowserFocusMode(tab: String?)
    /// The window's sidebar was shown or hidden. Hiding it while it (or
    /// its rename field) has the keyboard returns focus to the content.
    case sidebarVisibility(hidden: Bool)
    /// The pane this window's record saved for `workspace` (relaunch): the
    /// pane that workspace focuses when it first shows, unless focus there
    /// already moved.
    case restoredPane(String, workspace: String)
}

extension FocusEvent {
    /// Moves focus or selection on purpose (a pane or tab choice, a focus
    /// target, a new intent or expectation, a drop landing): what an action
    /// run without view-change permission must not send. Reports of what
    /// AppKit or the daemon did (responder, topology, key, overlays) are not.
    /// The rule is `cmux-focus-core`'s `FocusEvent::changes_view`.
    public var changesView: Bool { FocusMachine.changesView(self) }
}

/// Outputs of the reducer, applied by `FocusEffectApplier` after the
/// reducer returns. Each is idempotent. Read from `cmux-focus-core`'s
/// typed reply.
public nonisolated enum FocusEffect: Hashable, Sendable, Codable {
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

public extension FocusEvent {
    /// A focus or selection change the person made by mouse, keyboard or palette: not the CLI, a script, the app or the
    /// daemon (a keyboard claim of the person's new terminal ends at one, `CreationKeyboardClaims`).
    var isPersonsOwn: Bool {
        switch self {
        case .focusPane(_, _, let source), .selectTab(_, _, _, let source), .focusTarget(_, let source), .responder(_, let source):
            source == .mouse || source == .keyboard || source == .palette
        default: false
        }
    }

    /// A focus choice of the person's (``FocusState/personMoveSeq``): a focus or selection move from their own entry (mouse,
    /// keyboard, palette), or the window's responder report of their click in a view. A responder change inside a key's
    /// dispatch is none, nor is any move of automation's. (`focusPane`, `selectTab` and `focusTarget`, the other events
    /// ``isPersonsOwn`` names, always change the view: no FFI call to ask.)
    var choosesFocusAsPerson: Bool {
        if case .responder(_, let source) = self { return source == .mouse }
        return isPersonsOwn
    }

    /// A focus choice of a run the person chose from a menu (``FocusMachine/send(_:into:menuPick:)``): any focus or selection
    /// move, and any responder report no key's dispatch made. AppKit runs a chosen item's action outside an input event's
    /// dispatch, so its events carry the CLI's or the app's source; a held key run again inside the run's task carries the
    /// keyboard's, and a key's responder change is no focus choice (round 10 of #35275).
    var choosesFocusInMenuPick: Bool {
        switch self {
        case .responder(_, let source): source != .keyboard
        case .focusPane, .selectTab, .focusTarget: true
        default: false
        }
    }
}
