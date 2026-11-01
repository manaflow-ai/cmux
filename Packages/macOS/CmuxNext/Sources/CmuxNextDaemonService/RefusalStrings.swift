import CmuxNextDaemon
public import CmuxNextLayout
public import Foundation

/// Localized refusal and failure reasons for action handlers. The control
/// socket returns them as `unavailable: <reason>`; keyboard, menu, and
/// palette runs log them. Keys live in Resources/Refusals.xcstrings (en, ja).
/// A raw object id (`tab_…`, `ws_…`, a pane or window id) is never shown:
/// a reason about a missing object says so in words, and its `id`
/// parameter is for call sites and logs only (ToastCopyTests). A daemon capability
/// id (`profiles-v1`) is never shown: the capability gate's reasons say what
/// the user can do instead (CapabilityRefusalTests scans every string).
public nonisolated enum RefusalStrings {
    public static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "Refusals", bundle: .module)
    }

    /// A feature an administrator turned off (DisabledFeatures).
    public static var turnedOffByOrganization: String { text("refusal.policy.turnedOff", "Turned off by your organization") }

    public static func format(_ key: StaticString, _ value: String.LocalizationValue, _ arguments: any CVarArg...) -> String {
        String(format: text(key, value), arguments: arguments)
    }

    /// A direction word for "no pane left of ..." style reasons.
    public static func direction(_ direction: LayoutDirection) -> String {
        switch direction {
        case .left: directionLeft
        case .right: directionRight
        case .up: directionUp
        case .down: directionDown
        }
    }

    /// A move between an incognito window and a normal one.
    public static var incognitoMismatch: String {
        text("handlers.refusal.incognitoMismatch", "Incognito and normal windows can't share workspaces, tabs or screens.")
    }
    /// Move Space to This Window or Merge All Windows would close a window still creating a workspace.
    public static var gatherWhileCreating: String {
        text("handlers.refusal.gatherWhileCreating", "A new workspace is still opening in a window this would close. Try again in a moment.")
    }
    /// Move Space to This Window or Merge All Windows would take a workspace out of a window that keeps its own browser tabs.
    public static var gatherLocalTabs: String {
        text("handlers.refusal.gatherLocalTabs", "A window this would change keeps browser tabs that can't move with its workspaces. Close those tabs first.")
    }
    public static var chromiumUnavailable: String { text("handlers.refusal.chromiumUnavailable", "Chromium is not available in this build.") }
    /// A window action before the window has registered (the launch window, still restoring).
    public static var windowNotReady: String { text("handlers.refusal.windowNotReady", "This window isn't ready yet. Try again in a moment.") }
    public static var homeNotReady: String { text("handlers.refusal.homeNotReady", "Home is not ready yet.") }
    /// Close New Message (`home.closeNewMessage`) while no New Message draft is open.
    public static var noNewMessage: String { text("handlers.refusal.noNewMessage", "There is no new message to close.") }
    /// A promote (new workspace, new window) of a Home tab (`TabPromotion`).
    public static var homeKeepsItsTabs: String { text("handlers.refusal.homeKeepsItsTabs", "Home's tabs stay in Home.") }
    /// The user's close of a permanent docked column (cmux-tui `dock-column-permanent`).
    public static var columnStaysDocked: String { text("handlers.refusal.columnStaysDocked", "This column stays docked and can't be closed.") }
    /// The user's close of Home's tab in its pinned dock column (cmux-tui `dock-column-pinned`).
    public static var homeTabStays: String { text("handlers.refusal.homeTabStays", "Home stays open in its column.") }
    /// The user's close the daemon refused for another reason.
    public static var closeRefused: String { text("handlers.refusal.closeRefused", "The tab could not be closed.") }
    /// A Home action that opens the page or a sheet, run by automation that may not change the view.
    public static var homeNeedsFocus: String {
        text("handlers.refusal.homeNeedsFocus",
             "Opening Home needs focus: run it with focus, or give its arguments to run it in the background.")
    }
    /// A page asked for a person-only action (import, file picker) without a click or key in it.
    public static var personOnlyFromPage: String {
        text("handlers.refusal.personOnlyFromPage", "Only you can start this, with a click or key in the page.")
    }
    /// A tab action (Cmd-W) while a top page shows: pages have no tabs and do not close.
    public static var topPageHasNoTabs: String { text("handlers.refusal.topPageHasNoTabs", "This page has no tabs.") }
    /// Close Workspace with no target while a top page shows (HomeRules).
    public static var topPageIsNotAWorkspace: String { text("handlers.refusal.topPageIsNotAWorkspace", "This page is not a workspace.") }
    /// A close of the store's home workspace (`home_not_closable`).
    public static var homeNotClosable: String { text("handlers.refusal.homeNotClosable", "Home can't be closed.") }
    public static var homeAttachNoHome: String {
        text("handlers.refusal.homeAttachNoHome", "Open a Home conversation to attach files.")
    }
    public static var homeReplyNoSelection: String {
        text("handlers.refusal.homeReplyNoSelection", "Select text in one message of a Home conversation to reply to it.")
    }
    public static var homeQuoteNoHome: String {
        text("handlers.refusal.homeQuoteNoHome", "Open a Home conversation to quote in chat.")
    }
    public static var homeFlightRecorderOff: String {
        text("handlers.refusal.homeFlightRecorderOff", "The flight recorder is off, or no Home conversation is open. Turn it on in Debug Settings > Home.")
    }
    public static func homeAttachNoFile(_ path: String) -> String {
        String(format: text("handlers.refusal.homeAttachNoFile", "No file at “%@”."), path)
    }
    public static var notABrowserTab: String { text("handlers.refusal.notABrowserTab", "This tab is not a web page.") }
    /// Open in WebKit on a Cloud proxied tab: WebKit would load this Mac's localhost.
    public static var proxiedTabStaysInChromium: String {
        text("handlers.refusal.proxiedTabStaysInChromium", "This tab shows a cloud machine's localhost through its proxy, so it stays in Chromium.")
    }
    static var directionLeft: String { text("handlers.refusal.directionLeft", "left") }
    static var directionRight: String { text("handlers.refusal.directionRight", "right") }
    static var directionUp: String { text("handlers.refusal.directionUp", "up") }
    static var directionDown: String { text("handlers.refusal.directionDown", "down") }
    /// Why an action that needs the local daemon's `capability` is off. The
    /// bundled daemon is built from this tree and serves every capability in
    /// `DaemonCapability.required` and `optional` (check-daemon-capabilities.sh),
    /// so a running daemon without one is an older build: restarting cmux
    /// updates it. Any other capability has no daemon half in this build yet.
    /// The id itself is never shown.
    public static func needsDaemonCapability(_ capability: String) -> String {
        DaemonCapability.isServedByBundledDaemon(capability) ? restartToUpdateDaemon : notInThisVersion
    }
    /// The running local daemon is older than the app.
    public static var restartToUpdateDaemon: String {
        text("handlers.refusal.restartToUpdateDaemon", "cmux’s background service is out of date. Quit and reopen cmux to update it.")
    }
    /// A feature with no implementation in this build.
    static var notInThisVersion: String { text("handlers.refusal.notInThisVersion", "Not available in this version of cmux yet.") }
    /// The local daemon has not answered yet (first connection or a restart).
    public static var daemonConnecting: String {
        text("handlers.refusal.daemonConnecting", "cmux is still starting its background service. Try again in a moment.")
    }
    /// The local daemon could not start (the window shows why).
    static var daemonUnavailable: String {
        text("handlers.refusal.daemonUnavailable", "cmux could not start its background service. Quit and reopen cmux to try again.")
    }
    /// The local daemon is alive but has spent over 2 minutes restoring the
    /// session's terminals (`server.restore_timeout`); cmux keeps trying.
    public static var daemonRestoreTimedOut: String {
        text("handlers.refusal.daemonRestoreTimedOut",
             "cmux is still restoring your terminals. This is taking longer than 2 minutes; cmux keeps trying.")
    }
    /// A daemon error as a user-facing reason: a missing capability goes
    /// through the capability gate's text, never its id.
    public static func describe(_ error: any Error) -> String {
        if case DaemonError.missingCapabilities(let names) = error { return needsDaemonCapability(names.first ?? "") }
        if case DaemonError.sessionRestoreTimedOut = error { return daemonRestoreTimedOut }
        return String(describing: error)
    }
    /// The home session's spaces and workspace groups are not loaded yet.
    static var personalStateLoading: String {
        text("handlers.refusal.personalStateLoading", "Spaces and workspace groups are still loading. Try again in a moment.")
    }
    /// The home session registry has no record of this machine yet, so it has no icon to set.
    public static var machineIconNotRegistered: String {
        text("handlers.refusal.machineIconNotRegistered", "This machine isn't registered yet. Try again in a moment.")
    }
    /// A Cloud machine's own cmux is older than this app.
    static var updateCloudMachine: String { text("handlers.refusal.updateCloudMachineCmux", "Update cmux on this Cloud machine to use this.") }
    /// A feature this build has no implementation of; `feature` names it for
    /// call sites and logs only and is never shown.
    public static func needsAppCapability(_ feature: String) -> String { notInThisVersion }
    public static func notShownInAnyWindow(_ target: String) -> String { format("handlers.refusal.notShownInAnyWindow", "%@ is not shown in any window", target) }
    /// A split of the agent chat dock, which is a docked region, not a split pane.
    public static var chatDockCannotSplit: String { text("handlers.refusal.chatDockCannotSplit", "The agent chat can't be split.") }
    /// A terminal, browser or tab group moved into the agent chat dock.
    public static var chatDockTakesOnlyChats: String {
        text("handlers.refusal.chatDockTakesOnlyChats", "The agent chat column holds only agent chats.")
    }
    public static var notEnoughRoomToSplit: String { text("handlers.refusal.notEnoughRoomToSplit", "not enough room to split this pane") }
    public static var focusedPaneHasNoTab: String { text("handlers.refusal.focusedPaneHasNoTab", "the focused pane has no tab") }
    public static func noTab(_ id: String) -> String { text("handlers.refusal.tabGone", "That tab is no longer open.") }
    public static func noPaneID(_ id: String) -> String { text("handlers.refusal.paneGone", "That pane is no longer open.") }
    public static var workspaceArgumentRequired: String { text("handlers.refusal.workspaceArgumentRequired", "a workspace argument is required") }
    /// A workspace that is not open (closed, or never was). `id` is for call
    /// sites and logs only: a toast or the socket never shows a raw id.
    public static func noWorkspace(_ id: String) -> String { text("handlers.refusal.workspaceGone", "That workspace is no longer open.") }
    public static func paneHasNoWorkspaceView(_ id: String) -> String { text("handlers.refusal.paneWorkspaceNotShown", "That pane's workspace isn't shown in any window.") }
    public static var noWindowShowsWorkspace: String { text("handlers.refusal.noWindowShowsWorkspace", "no window shows a workspace") }
    public static func tabHasNoLiveContent(_ id: String) -> String { text("handlers.refusal.tabNotLoaded", "That tab hasn't loaded yet.") }
    public static var notATerminal: String { text("handlers.refusal.notATerminal", "the tab is not a terminal") }
    public static var tabNotDead: String { text("handlers.refusal.tabNotDead", "only a terminal tab whose shell ended can restart") }
    public static var noWindowOpen: String { text("handlers.refusal.noWindowOpen", "no window is open") }
    public static var noWindowForRename: String { text("handlers.refusal.noWindowForRename", "no window for the rename prompt") }
    public static var indexRequired: String { text("handlers.refusal.indexRequired", "an index 1-9 is required") }
    public static func screenCount(_ count: Int) -> String { format("handlers.refusal.screenCount", "the workspace has %lld screens", count) }
    public static func noScreen(_ id: String) -> String { text("handlers.refusal.screenGone", "That screen is no longer open.") }
    public static var workspaceHasNoScreen: String { text("handlers.refusal.workspaceHasNoScreen", "the workspace has no screen") }
    public static var workspaceHasOneScreen: String { text("handlers.refusal.workspaceHasOneScreen", "the workspace has one screen") }
    public static var paneArgumentRequired: String { text("handlers.refusal.paneArgumentRequired", "a pane argument is required") }
    public static var paneCannotSwapWithItself: String { text("handlers.refusal.paneCannotSwapWithItself", "a pane cannot swap with itself") }
    public static var noLiveTerminal: String { text("handlers.refusal.noLiveTerminal", "the workspace shows no live terminal") }
    public static func noPaneInDirection(_ direction: String) -> String { format("handlers.refusal.noPaneInDirection", "no pane %@ of the focused pane", direction) }
    public static var screenHasOnePane: String { text("handlers.refusal.screenHasOnePane", "the screen has one pane") }
    public static func noDividerToMove(_ direction: String) -> String { format("handlers.refusal.noDividerToMove", "no divider to move %@ (or it is at its limit)", direction) }
    public static var screenHasNoSplits: String { text("handlers.refusal.screenHasNoSplits", "the screen has no splits") }
    /// A canvas action on a screen that shows its split or column layout.
    public static var canvasNotShown: String { text("handlers.refusal.canvasNotShown", "this screen is not a canvas; use Toggle Canvas Layout first") }
    /// A canvas arrangement with nothing to move, or an overview of an empty canvas.
    public static var canvasNothingToArrange: String {
        text("handlers.refusal.canvasNothingToArrange", "nothing to arrange: the canvas needs two panes that this would move")
    }
    /// A canvas zoom that is already at its limit (or at actual size).
    public static var canvasZoomLimit: String { text("handlers.refusal.canvasZoomLimit", "the canvas is already at that zoom") }
    public static var controlListenerNotRunning: String {
        text("handlers.refusal.controlListenerNotRunning", "The CLI listener is not running in this app.")
    }
    public static func controlListenerRestartFailed(_ reason: String) -> String {
        format("handlers.refusal.controlListenerRestartFailed", "The CLI listener could not restart: %@", reason)
    }
    public static var noWorkspacePullRequestLinks: String {
        text("handlers.refusal.noWorkspacePullRequestLinks", "This workspace has no pull request links.")
    }
    public static var noRecentlyClosedTab: String { text("handlers.refusal.noRecentlyClosedTab", "no recently closed tab") }
    public static var noRecentlyClosedWorkspace: String { text("handlers.refusal.noRecentlyClosedWorkspace", "no recently closed workspace") }
    static var noRecentlyClosedItem: String { text("handlers.refusal.noRecentlyClosedItem", "nothing was closed recently") }
    public static func noClosedItem(_ id: String) -> String { text("handlers.refusal.closedItemGone", "That closed item can no longer be reopened.") }
    public static var paneHasNoTabs: String { text("handlers.refusal.paneHasNoTabs", "the pane has no tabs") }
    public static var tabArgumentRequired: String { text("handlers.refusal.tabArgumentRequired", "a tab argument is required") }
    public static var tabAtEdge: String { text("handlers.refusal.tabAtEdge", "the tab is already at the edge") }
    public static var screenHasNoOtherPane: String { text("handlers.refusal.screenHasNoOtherPane", "the screen has no other pane") }
    public static var noPaneWithNumber: String { text("handlers.refusal.noPaneWithNumber", "the screen has no pane with that number") }
    public static func noPaneInDirectionOfTab(_ direction: String) -> String { format("handlers.refusal.noPaneInDirectionOfTab", "no pane %@ of the tab", direction) }
    public static var sessionLocalCannotRename: String { text("handlers.refusal.sessionLocalCannotRename", "session-local tabs cannot be renamed") }
    public static var sessionLocalHasNoName: String { text("handlers.refusal.sessionLocalHasNoName", "session-local tabs have no name") }
    /// A Close Tab press aimed at a pane the press before it emptied (`PaneCloseAim` in the app).
    public static var closeAimedAtClosedPane: String { text("handlers.refusal.closeAimedAtClosedPane", "That pane closed. Press again to close a tab in this pane.") }
    public static var pinnedTabKept: String { text("handlers.refusal.pinnedTabKept", "Pinned tabs stay open. Right-click the tab and choose Close Tab to close it.") }
    public static var sessionLocalCannotPin: String { text("handlers.refusal.sessionLocalCannotPin", "session-local tabs cannot be pinned") }
    public static var neverHibernateNoSite: String { text("handlers.refusal.neverHibernateNoSite", "This tab shows no website.") }
    public static var hibernateVisibleTab: String { text("handlers.refusal.hibernateVisibleTab", "Only a hidden tab can hibernate.") }
    public static var hibernateUnsupported: String {
        text("handlers.refusal.hibernateUnsupported", "This page cannot keep its history when it hibernates.")
    }
    public static var hibernateFormSubmission: String {
        text("handlers.refusal.hibernateFormSubmission", "This page shows the result of a form. It stays loaded so the form is not sent again.")
    }
    public static var wakeNotHibernated: String { text("handlers.refusal.wakeNotHibernated", "This tab is not hibernated.") }
    public static var terminalCannotReload: String { text("handlers.refusal.terminalCannotReload", "terminal tabs cannot reload; use Reconnect Pane") }
    public static var audioMuteNeedsPage: String { text("handlers.refusal.audioMuteNeedsPage", "only a loaded browser tab can be muted") }
    public static var workspaceHasNoAudio: String { text("handlers.refusal.workspaceHasNoAudio", "No tab in this workspace plays sound") }
    public static func noColumnShown(_ id: String) -> String { text("handlers.refusal.columnNotShown", "That column isn't shown.") }
    public static var addSecondColumnFirst: String { text("handlers.refusal.addSecondColumnFirst", "Add a second column first") }
    public static var columnAlreadyHasWidth: String { text("handlers.refusal.columnAlreadyHasWidth", "the column already has that width") }
    public static var columnTooNarrowToSplit: String { text("handlers.refusal.columnTooNarrowToSplit", "Not enough room to split this column") }
    /// cmux.json `layout.rows` is false (plans/cmux-next/rows.md O2).
    public static var rowsTurnedOff: String { text("handlers.refusal.rowsTurnedOff", "Rows are turned off (layout.rows)") }
    public static var columnAlreadyDocked: String { text("handlers.refusal.columnAlreadyDocked", "the column is already docked there") }
    public static var columnNotDocked: String { text("handlers.refusal.columnNotDocked", "the column is not docked") }
    /// Docking a tab whose kind cannot leave a fresh tab behind (an agent
    /// chat, an incognito page) when it is the screen's only tab.
    public static var openSecondTabToDock: String { text("handlers.refusal.openSecondTabToDock", "Open a second tab to dock this one") }
    public static var lastScrollingColumn: String { text("handlers.refusal.lastScrollingColumn", "at least one column must scroll") }
    public static func noColumnInDirection(_ direction: String) -> String { format("handlers.refusal.noColumnInDirection", "no column to the %@", direction) }
    public static var columnAtEdge: String { text("handlers.refusal.columnAtEdge", "the column is already at the edge") }
    public static func paneHasNoDaemonHandle(_ id: String) -> String { text("handlers.refusal.paneNotReady", "That pane isn't ready yet.") }
}
