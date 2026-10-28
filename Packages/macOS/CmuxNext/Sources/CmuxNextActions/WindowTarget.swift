/// The window a command runs against, resolved ONCE at its entrypoint from the input itself (the
/// multi-window P0, Lawrence 2026-10-28: "keyboard shortcuts dont work, and clicking on
/// home/workspaces might bring me to the wrong window. we need to completely eliminate this error
/// class"). Chrome runs every command against an explicit `Browser*` (`BrowserWindowInterface`),
/// the window the input came from; it never asks "which window is current" later. This is that.
///
/// The App's one resolver (`WindowManager.resolveTarget(for:)`, CmuxNextApp/Windows/WindowTarget.swift) is,
/// for action runs, the only place that reads AppKit's window state to decide a window. Everything else gets a window
/// from its input: ``ActionInvocation/windowID`` (set when the run starts and kept for the run's tasks
/// in ``ActionRunScope/windowID``), the view's own window, or an explicit argument.
public nonisolated struct WindowTarget: Hashable, Sendable {
    /// What named the window, in the resolver's order (`WindowManager.resolveTarget(for:)`).
    public enum Source: String, Hashable, Sendable {
        /// The input named it: the view's own window (a sidebar row, the Home button, a tab strip),
        /// the CLI's `--window`, a window action's target, or the run this one is nested in.
        case named
        /// The window the event in dispatch came from (`WindowManager.dispatching(eventFrom:_:)`),
        /// or the window that event's own action brought forward.
        case event
        /// A person's run with no event window (a menu item): the key window at the run's start,
        /// which is the key window at the menu's event.
        case keyWindowAtEntry
        /// The window that owns the run's target object (its workspace or tab).
        case targetOwner
        /// The app's most recently active window, from its own window order (the registry's recency: every
        /// key change, order-in and person's key or click updates it); never the key window read later.
        case lastPersonActive
        /// The window that last became key, when the order lists no open window (a launch window not
        /// registered yet).
        case front
        /// The launch window before the restore registered it (it shows the connecting state).
        case launch
    }

    /// The window's id (`WindowState.id`).
    public let id: String
    public let source: Source

    public init(id: String, source: Source) {
        self.id = id
        self.source = source
    }
}
