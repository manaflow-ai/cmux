import CmuxNextDaemon
import CmuxNextLayout
import Foundation

/// Localized refusal and failure reasons for action handlers. The control
/// socket returns them as `unavailable: <reason>`; keyboard, menu, and
/// palette runs log them. Keys live in Resources/Refusals.xcstrings (en, ja).
/// Identifiers are format arguments, never translated. A daemon capability
/// id (`profiles-v1`) is never shown: the capability gate's reasons say what
/// the user can do instead (CapabilityRefusalTests scans every string).
nonisolated enum RefusalStrings {
    static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "Refusals", bundle: .module)
    }

    /// A feature an administrator turned off (DisabledFeatures).
    static var turnedOffByOrganization: String { text("refusal.policy.turnedOff", "Turned off by your organization") }

    static func format(_ key: StaticString, _ value: String.LocalizationValue, _ arguments: any CVarArg...) -> String {
        String(format: text(key, value), arguments: arguments)
    }

    /// A direction word for "no pane left of ..." style reasons.
    static func direction(_ direction: LayoutDirection) -> String {
        switch direction {
        case .left: directionLeft
        case .right: directionRight
        case .up: directionUp
        case .down: directionDown
        }
    }

    /// A move between an incognito window and a normal one.
    static var incognitoMismatch: String {
        text("handlers.refusal.incognitoMismatch", "Incognito and normal windows can't share workspaces, tabs or screens.")
    }
    static var chromiumUnavailable: String { text("handlers.refusal.chromiumUnavailable", "Chromium is not available in this build.") }
    static var homeNotReady: String { text("handlers.refusal.homeNotReady", "Home is not ready yet.") }
    /// The user's close of a permanent docked column (cmux-tui `dock-column-permanent`).
    static var columnStaysDocked: String { text("handlers.refusal.columnStaysDocked", "This column stays docked and can't be closed.") }
    /// The user's close the daemon refused for another reason.
    static var closeRefused: String { text("handlers.refusal.closeRefused", "The tab could not be closed.") }
    /// A Home action that opens the page or a sheet, run by automation that may not change the view.
    static var homeNeedsFocus: String {
        text("handlers.refusal.homeNeedsFocus",
             "Opening Home needs focus: run it with focus, or give its arguments to run it in the background.")
    }
    /// A page asked for a person-only action (import, file picker) without a click or key in it.
    static var personOnlyFromPage: String {
        text("handlers.refusal.personOnlyFromPage", "Only you can start this, with a click or key in the page.")
    }
    /// A tab action (Cmd-W) while a top page shows: pages have no tabs and do not close.
    static var topPageHasNoTabs: String { text("handlers.refusal.topPageHasNoTabs", "This page has no tabs.") }
    /// Close Workspace with no target while a top page shows (HomeRules).
    static var topPageIsNotAWorkspace: String { text("handlers.refusal.topPageIsNotAWorkspace", "This page is not a workspace.") }
    /// A close of the store's home workspace (`home_not_closable`).
    static var homeNotClosable: String { text("handlers.refusal.homeNotClosable", "Home can't be closed.") }
    static var homeAttachNoHome: String {
        text("handlers.refusal.homeAttachNoHome", "Open a Home conversation to attach files.")
    }
    static var homeFlightRecorderOff: String {
        text("handlers.refusal.homeFlightRecorderOff", "The flight recorder is off, or no Home conversation is open. Turn it on in Debug Settings > Home.")
    }
    static func homeAttachNoFile(_ path: String) -> String {
        String(format: text("handlers.refusal.homeAttachNoFile", "No file at “%@”."), path)
    }
    static var notABrowserTab: String { text("handlers.refusal.notABrowserTab", "This tab is not a web page.") }
    /// Open in WebKit on a Cloud proxied tab: WebKit would load this Mac's localhost.
    static var proxiedTabStaysInChromium: String {
        text("handlers.refusal.proxiedTabStaysInChromium", "This tab shows a cloud machine's localhost through its proxy, so it stays in Chromium.")
    }
    static var directionLeft: String { text("handlers.refusal.directionLeft", "left") }
    static var directionRight: String { text("handlers.refusal.directionRight", "right") }
    static var directionUp: String { text("handlers.refusal.directionUp", "up") }
    static var directionDown: String { text("handlers.refusal.directionDown", "down") }
    /// Why an action that needs the local daemon's `capability` is off. The
    /// bundled daemon is built from this tree and serves every capability in
    /// `DaemonCapabilities.required` and `optional` (check-daemon-capabilities.sh),
    /// so a running daemon without one is an older build: restarting cmux
    /// updates it. Any other capability has no daemon half in this build yet.
    /// The id itself is never shown.
    static func needsDaemonCapability(_ capability: String) -> String {
        DaemonCapabilities.shared.isServedByBundledDaemon(capability) ? restartToUpdateDaemon : notInThisVersion
    }
    /// The running local daemon is older than the app.
    static var restartToUpdateDaemon: String {
        text("handlers.refusal.restartToUpdateDaemon", "cmux’s background service is out of date. Quit and reopen cmux to update it.")
    }
    /// A feature with no implementation in this build.
    static var notInThisVersion: String { text("handlers.refusal.notInThisVersion", "Not available in this version of cmux yet.") }
    /// The local daemon has not answered yet (first connection or a restart).
    static var daemonConnecting: String {
        text("handlers.refusal.daemonConnecting", "cmux is still starting its background service. Try again in a moment.")
    }
    /// The local daemon could not start (the window shows why).
    static var daemonUnavailable: String {
        text("handlers.refusal.daemonUnavailable", "cmux could not start its background service. Quit and reopen cmux to try again.")
    }
    /// A daemon error as a user-facing reason: a missing capability goes
    /// through the capability gate's text, never its id.
    static func describe(_ error: any Error) -> String {
        if case DaemonError.missingCapabilities(let names) = error { return needsDaemonCapability(names.first ?? "") }
        return String(describing: error)
    }
    /// The home session's spaces and workspace groups are not loaded yet.
    static var personalStateLoading: String {
        text("handlers.refusal.personalStateLoading", "Spaces and workspace groups are still loading. Try again in a moment.")
    }
    /// A Cloud machine's own cmux is older than this app.
    static var updateCloudMachine: String { text("handlers.refusal.updateCloudMachineCmux", "Update cmux on this Cloud machine to use this.") }
    /// A feature this build has no implementation of; `feature` names it for
    /// call sites and logs only and is never shown.
    static func needsAppCapability(_ feature: String) -> String { notInThisVersion }
    static func notShownInAnyWindow(_ target: String) -> String { format("handlers.refusal.notShownInAnyWindow", "%@ is not shown in any window", target) }
    static var notEnoughRoomToSplit: String { text("handlers.refusal.notEnoughRoomToSplit", "not enough room to split this pane") }
    static var focusedPaneHasNoTab: String { text("handlers.refusal.focusedPaneHasNoTab", "the focused pane has no tab") }
    static func noTab(_ id: String) -> String { format("handlers.refusal.noTab", "no tab %@", id) }
    static func noPaneID(_ id: String) -> String { format("handlers.refusal.noPaneID", "no pane %@", id) }
    static var workspaceArgumentRequired: String { text("handlers.refusal.workspaceArgumentRequired", "a workspace argument is required") }
    static func noWorkspace(_ id: String) -> String { format("handlers.refusal.noWorkspace", "no workspace %@", id) }
    static func paneHasNoWorkspaceView(_ id: String) -> String { format("handlers.refusal.paneHasNoWorkspaceView", "pane %@ has no workspace view", id) }
    static var noWindowShowsWorkspace: String { text("handlers.refusal.noWindowShowsWorkspace", "no window shows a workspace") }
    static func tabHasNoLiveContent(_ id: String) -> String { format("handlers.refusal.tabHasNoLiveContent", "tab %@ has no live content", id) }
    static var notATerminal: String { text("handlers.refusal.notATerminal", "the tab is not a terminal") }
    static var noWindowOpen: String { text("handlers.refusal.noWindowOpen", "no window is open") }
    static var noWindowForRename: String { text("handlers.refusal.noWindowForRename", "no window for the rename prompt") }
    static var indexRequired: String { text("handlers.refusal.indexRequired", "an index 1-9 is required") }
    static func screenCount(_ count: Int) -> String { format("handlers.refusal.screenCount", "the workspace has %lld screens", count) }
    static func noScreen(_ id: String) -> String { format("handlers.refusal.noScreen", "no screen %@", id) }
    static var workspaceHasNoScreen: String { text("handlers.refusal.workspaceHasNoScreen", "the workspace has no screen") }
    static var workspaceHasOneScreen: String { text("handlers.refusal.workspaceHasOneScreen", "the workspace has one screen") }
    static var paneArgumentRequired: String { text("handlers.refusal.paneArgumentRequired", "a pane argument is required") }
    static var paneCannotSwapWithItself: String { text("handlers.refusal.paneCannotSwapWithItself", "a pane cannot swap with itself") }
    static var noLiveTerminal: String { text("handlers.refusal.noLiveTerminal", "the workspace shows no live terminal") }
    static func noPaneInDirection(_ direction: String) -> String { format("handlers.refusal.noPaneInDirection", "no pane %@ of the focused pane", direction) }
    static var screenHasOnePane: String { text("handlers.refusal.screenHasOnePane", "the screen has one pane") }
    static func noDividerToMove(_ direction: String) -> String { format("handlers.refusal.noDividerToMove", "no divider to move %@ (or it is at its limit)", direction) }
    static var screenHasNoSplits: String { text("handlers.refusal.screenHasNoSplits", "the screen has no splits") }
    static var canvasUnported: String { text("handlers.refusal.canvasUnported", "needs canvas layout, which cmux-next does not have yet") }
    static var simulatorUnported: String { text("handlers.refusal.simulatorUnported", "needs simulator panes, which cmux-next does not have yet") }
    static var filesPaneUnported: String { text("handlers.refusal.filesPaneUnported", "needs the Files panel as a pane (not in cmux-next yet)") }
    static var findPaneUnported: String { text("handlers.refusal.findPaneUnported", "needs the Find panel as a pane (not in cmux-next yet)") }
    static var vaultPaneUnported: String { text("handlers.refusal.vaultPaneUnported", "needs the Vault panel as a pane (not in cmux-next yet)") }
    static var cloudPaneUnported: String { text("handlers.refusal.cloudPaneUnported", "needs the Cloud panel as a pane (not in cmux-next yet)") }
    static var noRecentlyClosedTab: String { text("handlers.refusal.noRecentlyClosedTab", "no recently closed tab") }
    static var noRecentlyClosedItem: String { text("handlers.refusal.noRecentlyClosedItem", "nothing was closed recently") }
    static func noClosedItem(_ id: String) -> String { format("handlers.refusal.noClosedItem", "no recently closed item %@", id) }
    static var paneHasNoTabs: String { text("handlers.refusal.paneHasNoTabs", "the pane has no tabs") }
    static var tabArgumentRequired: String { text("handlers.refusal.tabArgumentRequired", "a tab argument is required") }
    static var tabAtEdge: String { text("handlers.refusal.tabAtEdge", "the tab is already at the edge") }
    static var screenHasNoOtherPane: String { text("handlers.refusal.screenHasNoOtherPane", "the screen has no other pane") }
    static func noPaneInDirectionOfTab(_ direction: String) -> String { format("handlers.refusal.noPaneInDirectionOfTab", "no pane %@ of the tab", direction) }
    static var sessionLocalCannotRename: String { text("handlers.refusal.sessionLocalCannotRename", "session-local tabs cannot be renamed") }
    static var sessionLocalHasNoName: String { text("handlers.refusal.sessionLocalHasNoName", "session-local tabs have no name") }
    static var pinnedTabKept: String { text("handlers.refusal.pinnedTabKept", "Pinned tabs stay open. Right-click the tab and choose Close Tab to close it.") }
    static var sessionLocalCannotPin: String { text("handlers.refusal.sessionLocalCannotPin", "session-local tabs cannot be pinned") }
    static var markUnreadUnsupported: String {
        text("handlers.refusal.markUnreadNotAvailable", "Marking as unread is not available yet. Only marking as read is.")
    }
    static var hibernateVisibleTab: String { text("handlers.refusal.hibernateVisibleTab", "Only a hidden tab can hibernate.") }
    static var hibernateUnsupported: String {
        text("handlers.refusal.hibernateUnsupported", "This page cannot keep its history when it hibernates.")
    }
    static var wakeNotHibernated: String { text("handlers.refusal.wakeNotHibernated", "This tab is not hibernated.") }
    static var terminalCannotReload: String { text("handlers.refusal.terminalCannotReload", "terminal tabs cannot reload; use Reconnect Pane") }
    static var fullWidthTabUnported: String { text("handlers.refusal.fullWidthTabUnported", "needs full-width tab support in the cmux-next tab strip") }
    static var audioMuteUnported: String { text("handlers.refusal.audioMuteUnported", "needs audio mute support in the cmux-next browser") }
    static func noColumnShown(_ id: String) -> String { format("handlers.refusal.noColumnShown", "no column %@ is shown", id) }
    static var addSecondColumnFirst: String { text("handlers.refusal.addSecondColumnFirst", "Add a second column first") }
    static var columnAlreadyHasWidth: String { text("handlers.refusal.columnAlreadyHasWidth", "the column already has that width") }
    static var columnTooNarrowToSplit: String { text("handlers.refusal.columnTooNarrowToSplit", "Not enough room to split this column") }
    /// cmux.json `layout.rows` is false (plans/cmux-next/rows.md O2).
    static var rowsTurnedOff: String { text("handlers.refusal.rowsTurnedOff", "Rows are turned off (layout.rows)") }
    static var columnAlreadyDocked: String { text("handlers.refusal.columnAlreadyDocked", "the column is already docked there") }
    static var columnNotDocked: String { text("handlers.refusal.columnNotDocked", "the column is not docked") }
    /// Docking a tab whose kind cannot leave a fresh tab behind (an agent
    /// chat, an incognito page) when it is the screen's only tab.
    static var openSecondTabToDock: String { text("handlers.refusal.openSecondTabToDock", "Open a second tab to dock this one") }
    static var lastScrollingColumn: String { text("handlers.refusal.lastScrollingColumn", "at least one column must scroll") }
    static func noColumnInDirection(_ direction: String) -> String { format("handlers.refusal.noColumnInDirection", "no column to the %@", direction) }
    static func moveColumnUnsupported(_ count: Int) -> String {
        format("handlers.refusal.moveColumnNotAvailable", "Moving a whole column is not available yet. This column has %lld panes; move them one at a time.", count)
    }
    static var columnAtEdge: String { text("handlers.refusal.columnAtEdge", "the column is already at the edge") }
    static func paneHasNoDaemonHandle(_ id: String) -> String { format("handlers.refusal.paneHasNoDaemonHandle", "pane %@ has no daemon handle", id) }
}
