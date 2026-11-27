import CmuxNextCompat
public import CmuxNextLayout

/// Chief in Side Panel (`home.chiefDock.sidePanel`; David Beyer's feedback, 2026-11-20: an option to open the Chief in
/// a dedicated side panel): while it is on, every window keeps its Chief panel docked at `home.chiefDock.edge` beside
/// the workspace it shows (never over Home). The app owns one and tells it the setting (``follow(on:edge:frames:)``)
/// and each change of its windows (``windowsDidChange(_:)``); both end in
/// ``WindowDockFrame/applyChiefSidePanel(_:edge:)``.
///
/// Turning it on docks and opens the panel in every window; a window that opens later gets it once. Turning it off
/// floats and hides each docked panel. The person's own moves stay theirs: Cmd-I hiding the panel, or a window
/// whose Chief they docked themselves while the setting was off, are never undone by an unrelated change. A launch
/// with the setting off changes nothing (cmux#37365: the Chief is never docked by default).
///
/// ```swift
/// let side = ChiefSidePanel()
/// side.follow(on: true, edge: .right, frames: windows)  // every window: the Chief docked at the right, open
/// side.windowsDidChange(windows + [newWindow])          // the new window gets it too; the others stay as they are
/// side.follow(on: false, edge: .right, frames: windows) // every docked Chief floats again, hidden
/// ```
@MainActor
public final class ChiefSidePanel {
    /// The setting this last applied; nil before the first ``follow(on:edge:frames:)``.
    public private(set) var applied: (on: Bool, edge: DockEdge)?
    /// The windows (``WindowDockFrame/frameWindowID``) already given the setting.
    private var seen: Set<String> = []
    /// The app's task that reads the setting into ``follow(on:edge:frames:)``; a new one cancels the old.
    public var follower: Task<Void, Never>? { didSet { oldValue?.cancel() } }

    public init() {}

    // Task handles are Sendable and cancel from any thread.
    nonisolated deinit { follower?.cancel() }

    /// The setting as it reads now (each change, and once at launch). A change applies to every window in `frames`;
    /// the same value again changes nothing. The first read applies only when on.
    public func follow(on: Bool, edge: DockEdge, frames: [any WindowDockFrame]) {
        let previous = applied
        guard previous.map({ $0.on != on || $0.edge != edge }) ?? true else { return }
        applied = (on, edge)
        seen = Set(frames.map(\.frameWindowID))
        // Off at launch, or still off: nothing to undo, and a Chief the person docked themselves stays docked.
        guard on || previous?.on == true else { return }
        for frame in frames { frame.applyChiefSidePanel(on, edge: edge) }
    }

    /// Follows ``WindowDockHost/chiefSidePanelOn`` and ``WindowDockHost/chiefDockEdge`` into every window of `host`
    /// (``follow(on:edge:frames:)``) until this side panel goes or follows again (``follower``).
    public func follow(host: any WindowDockHost) {
        // task-owner: this side panel (`follower`, cancelled when replaced or released); event-driven (Observation)
        follower = Task { [weak self, weak host] in
            for await (on, edge) in ObservationStream({ [weak host] in (host?.chiefSidePanelOn ?? false, host?.chiefDockEdge ?? .left) }) {
                guard let self, let host else { return }
                follow(on: on, edge: edge, frames: host.dockFrames)
            }
        }
    }

    /// Open Chief (the sidebar's Chief row) while the Chief is a side panel: the active window's docked panel shows
    /// and takes the keys (``WindowDockFrame/showChiefSidePanel()``). False when Chief in Side Panel is off, no
    /// window is open, or it shows Home, so the row opens the Chief's conversation there.
    public func open(host: any WindowDockHost) -> Bool {
        guard applied?.on == true, let frame = host.dockActiveFrame else { return false }
        return frame.showChiefSidePanel()
    }

    /// The app's windows changed (one opened, restored or closed): each window not given the setting yet gets it now
    /// while it is on.
    public func windowsDidChange(_ frames: [any WindowDockFrame]) {
        let ids = Set(frames.map(\.frameWindowID))
        let fresh = frames.filter { !seen.contains($0.frameWindowID) }
        seen = ids
        guard let applied, applied.on else { return }
        for frame in fresh { frame.applyChiefSidePanel(true, edge: applied.edge) }
    }
}
