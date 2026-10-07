public import Foundation

/// What a client does to its own view after a tab move lands: focus the
/// moved tab, show the workspace it landed in, make its window key. Client
/// view state, applied by the client that started the move after the
/// owner's echo (plans/cmux-next/OWNERSHIP-PRINCIPLES.md: focus, selection
/// and scroll change only from user-initiated actions; Option on drop files
/// the tab away).
public nonisolated struct DropReveal: Hashable, Sendable {
    /// Focus the moved tab in the window it landed in (reveals its pane:
    /// a new column scrolls into view).
    public var focusesTab: Bool
    /// The landing window switches to the workspace the tab landed in.
    public var showsWorkspace: Bool
    /// The landing window becomes key (only when this app is active, never
    /// in a no-activate launch, never across Spaces).
    public var makesKey: Bool

    public init(focusesTab: Bool, showsWorkspace: Bool, makesKey: Bool) {
        self.focusesTab = focusesTab
        self.showsWorkspace = showsWorkspace
        self.makesKey = makesKey
    }
}

public nonisolated enum DropRevealPolicy {
    public struct Facts: Hashable, Sendable {
        public var outcome: TabDragOutcome
        /// The owner applied the move (false: rejected, failed or offline).
        public var landed: Bool
        /// A user in this client started it (drag, palette, menu, key);
        /// false for CLI, MCP, scripts, agents and remote clients.
        public var userInitiated: Bool
        /// The invocation asked for focus explicitly (`focus: true`).
        public var focusRequested: Bool
        /// Option was held at the drop: file the tab away.
        public var filesAway: Bool
        /// It landed in another window than the one it came from.
        public var crossesWindows: Bool
        public var appActive: Bool
        public var noActivate: Bool
        /// The landing window is on the active Space.
        public var landingOnActiveSpace: Bool

        public init(outcome: TabDragOutcome, landed: Bool, userInitiated: Bool, focusRequested: Bool = false, filesAway: Bool = false,
                    crossesWindows: Bool = false, appActive: Bool = true, noActivate: Bool = false, landingOnActiveSpace: Bool = true) {
            self.outcome = outcome
            self.landed = landed
            self.userInitiated = userInitiated
            self.focusRequested = focusRequested
            self.filesAway = filesAway
            self.crossesWindows = crossesWindows
            self.appActive = appActive
            self.noActivate = noActivate
            self.landingOnActiveSpace = landingOnActiveSpace
        }
    }

    /// The view change for `facts`, or nil for none.
    public static func decide(_ facts: Facts) -> DropReveal? {
        guard facts.landed, !facts.filesAway, facts.userInitiated || facts.focusRequested else { return nil }
        let showsWorkspace: Bool
        let newWindow: Bool
        switch facts.outcome {
        case .cancel, .moveWindow, .moveWorkspaceToNewWindow, .moveWorkspace:
            // No tab moved (the window or workspace itself did).
            return nil
        case .strip, .newSplit, .newColumn, .newDock:
            showsWorkspace = false
            newWindow = false
        case .newWorkspace, .workspace:
            showsWorkspace = true
            newWindow = false
        case .tearOff:
            showsWorkspace = true
            newWindow = true
        }
        let keyable = facts.appActive && !facts.noActivate && facts.landingOnActiveSpace
        return DropReveal(focusesTab: true, showsWorkspace: showsWorkspace, makesKey: (newWindow || facts.crossesWindows) && keyable)
    }
}
