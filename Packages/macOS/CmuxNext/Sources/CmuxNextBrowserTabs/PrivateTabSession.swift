public import CmuxNextDaemon
import CmuxNextCompat

/// The incognito session while private tabs sit in normal windows (Leo, 2026-11-18: private tabs anywhere): it
/// lasts while one is left, and ends once no incognito window and no private tab remain.
public enum PrivateTabSession {
    /// Where New Private Tab opens.
    public enum Route: Equatable, Sendable {
        /// No pane to open it in, or a daemon without `private-tabs-v1`: a new incognito window.
        case incognitoWindow
        /// The active window is incognito: its new tab is private already.
        case windowTab
        /// A private tab in the focused pane of a normal window.
        case privateTab
    }

    /// New Private Tab's route for the active window's focused pane (`pane`), its window's kind and whether its
    /// daemon serves private browser tabs.
    public static func route(pane: Bool, incognitoWindow: Bool, served: Bool) -> Route {
        guard pane else { return .incognitoWindow }
        if incognitoWindow { return .windowTab }
        return served ? .privateTab : .incognitoWindow
    }

    /// The private tabs of `daemons`' workspaces that `skips` does not leave out (an incognito window's tabs close
    /// with it), with their daemons.
    public static func tabs<Daemon>(of daemons: [Daemon], store: (Daemon) -> DaemonStore, skips: (WorkspaceModel) -> Bool,
                                   isPrivate: (TabModel) -> Bool) -> [(TabModel, Daemon)] {
        var found: [(TabModel, Daemon)] = []
        for daemon in daemons {
            for workspace in store(daemon).workspaces where !skips(workspace) {
                for tab in workspace.screens.flatMap(\.panes).flatMap(\.tabs) where isPrivate(tab) { found.append((tab, daemon)) }
            }
        }
        return found
    }

    /// Calls `check` on each tab list change of `stores` (a private tab closed, or moved into an incognito window
    /// that then closed) until it returns false or the task is cancelled.
    public static func watch(_ stores: [DaemonStore], check: @escaping @MainActor () -> Bool) -> Task<Void, Never> {
        // task-owner: the caller stores it and cancels it when the incognito session ends
        Task {
            for await _ in ObservationStream({ stores.map(\.liveTabListRevision) }) {
                guard !Task.isCancelled, check() else { return }
            }
        }
    }
}
