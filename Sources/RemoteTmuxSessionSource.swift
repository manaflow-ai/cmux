import Foundation

/// The per-session control callbacks a ``RemoteTmuxSessionMirror`` registers.
///
/// Bundled into a value type because protocol requirements can't carry default
/// parameter values: every closure defaults to `nil`, so a call site names only the
/// events it cares about, exactly as the labeled `addObserver` form does.
@MainActor
struct RemoteTmuxSessionObservers {
    var onPaneOutput: ((_ paneId: Int, _ data: Data) -> Void)?
    var onPaneCwd: ((_ paneId: Int, _ path: String) -> Void)?
    var onPaneReflow: ((_ paneId: Int, _ noReflow: Bool) -> Void)?
    var onActivePaneChanged: ((_ windowId: Int, _ paneId: Int) -> Void)?
    var onSessionChanged: ((_ oldName: String, _ newName: String) -> Void)?
    var onTopologyChanged: (() -> Void)?
    var onExit: (() -> Void)?
    var onConnectionStateChanged: ((RemoteTmuxConnectionState) -> Void)?

    init(
        onPaneOutput: ((_ paneId: Int, _ data: Data) -> Void)? = nil,
        onPaneCwd: ((_ paneId: Int, _ path: String) -> Void)? = nil,
        onPaneReflow: ((_ paneId: Int, _ noReflow: Bool) -> Void)? = nil,
        onActivePaneChanged: ((_ windowId: Int, _ paneId: Int) -> Void)? = nil,
        onSessionChanged: ((_ oldName: String, _ newName: String) -> Void)? = nil,
        onTopologyChanged: (() -> Void)? = nil,
        onExit: (() -> Void)? = nil,
        onConnectionStateChanged: ((RemoteTmuxConnectionState) -> Void)? = nil
    ) {
        self.onPaneOutput = onPaneOutput
        self.onPaneCwd = onPaneCwd
        self.onPaneReflow = onPaneReflow
        self.onActivePaneChanged = onActivePaneChanged
        self.onSessionChanged = onSessionChanged
        self.onTopologyChanged = onTopologyChanged
        self.onExit = onExit
        self.onConnectionStateChanged = onConnectionStateChanged
    }
}

/// The per-session view a ``RemoteTmuxSessionMirror`` (and its child window mirrors)
/// consumes from its control stream: the session's window/pane topology, live output,
/// and the command surface the mirror issues.
///
/// The GA per-session ``RemoteTmuxControlConnection`` conforms directly — one
/// connection is one session, so the source *is* the connection. The multiplexed
/// transport supplies one ``RemoteTmuxSessionChannel`` per session over a single
/// shared stream, so the mirror renders a session identically whether it owns its
/// connection or shares one.
@MainActor
protocol RemoteTmuxSessionSource: AnyObject {
    /// Live transport state (host-global under a shared connection).
    var connectionState: RemoteTmuxConnectionState { get }
    /// `true` once the session has permanently ended.
    var exited: Bool { get }
    /// The tmux session id (`$N`), stable across renames, once known.
    var sessionId: Int? { get }
    /// This session's windows, keyed by tmux window id.
    var windowsByID: [Int: RemoteTmuxWindow] { get }
    /// This session's window ids in tmux index order.
    var windowOrder: [Int] { get }
    /// The active pane per window for this session.
    var activePaneByWindow: [Int: Int] { get }
    /// Cached foreground state per pane (drives close-confirmation / activity).
    var paneForegroundStates: [Int: RemoteTmuxPaneForegroundState] { get }
    /// Pane identities whose ownership is temporarily undecidable after their
    /// source window closes, retained until `list-windows` supplies a snapshot.
    var paneIDsRetainedUntilWindowList: Set<Int> { get }
    /// Layouts awaiting authoritative pane rectangles before publication.
    var pendingLayouts: [Int: RemoteTmuxPendingLayout] { get }
    /// The published window id owning each pane (topology-publication index).
    var publishedWindowIdByPane: [Int: Int] { get }
    /// Per-pane header-strip labels (expanded `pane-border-format`, styles stripped).
    var paneHeaderLabels: [Int: String] { get }
    /// Whether each window currently has `pane-border-status top`.
    var windowTitleRowsVisible: [Int: Bool] { get }
    /// The last size requested per window (the sizing claim/no-op check).
    var lastWindowSizes: [Int: (Int, Int)] { get }

    /// Registers the mirror's callbacks; returns a token for `removeObserver`.
    func addObserver(_ observers: RemoteTmuxSessionObservers) -> UUID
    func removeObserver(_ token: UUID)

    /// Releases this mirror's hold on its transport (observer slots, cached process
    /// ownership). This never touches sibling sessions that share the same transport.
    func releaseMirror()
    /// Ends the remote session (`kill == true`) or just this mirror's attachment
    /// (`kill == false`) using only channels the concrete transport itself can use.
    /// The controller owns workspace orchestration; the source owns transport action.
    func endSession(kill: Bool)

    /// Sends a raw tmux control command targeting this session's server-global ids.
    @discardableResult func send(_ command: String) -> Bool
    /// Creates a tmux window in-band and reports the new `@id` (or nil) back.
    @discardableResult func sendNewWindow(_ command: String, completion: @escaping (Int?) -> Void) -> Bool
    /// Sends a window-reorder command batch with optional verification callback.
    @discardableResult func sendWindowReorder(_ commands: [String], verification: ((Bool) -> Void)?) -> Bool
    /// Forwards typed input to a pane.
    @discardableResult func sendKeys(paneId: Int, data: Data) -> Bool
    /// Replays a pane's captured contents into a freshly-mounted surface.
    func seedPane(paneId: Int)
    /// Ends per-pane cwd / reflow / header subscriptions when a pane's mirror goes away.
    func unsubscribePanePath(paneId: Int)
    func unsubscribePaneReflow(paneId: Int)
    func unsubscribePaneHeader(paneId: Int)
    /// Sizes one window's grid (per-window `refresh-client -C`, with fallback).
    func setWindowSize(windowId: Int, columns: Int, rows: Int)
    /// Updates the cached session name (after a confirmed rename).
    func setSessionName(_ name: String)
    /// Applies a reordered window list to the cached order.
    func applyWindowReorder(_ reordered: [Int])
    /// Queries the foreground state of a window's panes.
    func queryWindowActivity(windowId: Int, completion: @escaping ([Int: RemoteTmuxPaneForegroundState]?) -> Void)
    /// Queries the foreground state of a single pane.
    func queryPaneActivity(paneId: Int, completion: @escaping ([Int: RemoteTmuxPaneForegroundState]?) -> Void)
    /// Pastes text into a pane.
    @discardableResult func pastePane(paneId: Int, text: String) -> Bool
}

/// GA: one control connection *is* one session, so the connection is its own source.
extension RemoteTmuxControlConnection: RemoteTmuxSessionSource {
    /// The linked-view model only needs "does this window show a top title row";
    /// current main models it richer as a per-window placement, so derive the Bool
    /// (main's connection has no stored `windowTitleRowsVisible`).
    var windowTitleRowsVisible: [Int: Bool] {
        windowTitleRowPlacements.mapValues { $0 == .top }
    }

    func releaseMirror() {}

    func endSession(kill: Bool) {
        // GA teardown still uses the controller's existing detach/one-shot kill path;
        // this conformance keeps shared lifecycle call sites source-dispatched without
        // changing the dedicated transport's ordering guarantees.
    }

    func addObserver(_ observers: RemoteTmuxSessionObservers) -> UUID {
        addObserver(
            onPaneOutput: observers.onPaneOutput,
            onPaneCwd: observers.onPaneCwd,
            onPaneReflow: observers.onPaneReflow,
            onActivePaneChanged: observers.onActivePaneChanged,
            onSessionChanged: observers.onSessionChanged,
            onTopologyChanged: observers.onTopologyChanged,
            onExit: observers.onExit,
            onConnectionStateChanged: observers.onConnectionStateChanged
        )
    }
}
