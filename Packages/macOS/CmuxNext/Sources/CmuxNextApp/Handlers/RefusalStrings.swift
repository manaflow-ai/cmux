import CmuxNextLayout
import Foundation

/// Localized refusal and failure reasons for action handlers. The control
/// socket returns them as `unavailable: <reason>`; keyboard, menu, and
/// palette runs log them. Keys live in Resources/Refusals.xcstrings (en, ja).
/// Identifiers and capability tokens are format arguments, never translated.
nonisolated enum RefusalStrings {
    static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "Refusals", bundle: .module)
    }

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
    static var notABrowserTab: String { text("handlers.refusal.notABrowserTab", "This tab is not a web page.") }
    static var directionLeft: String { text("handlers.refusal.directionLeft", "left") }
    static var directionRight: String { text("handlers.refusal.directionRight", "right") }
    static var directionUp: String { text("handlers.refusal.directionUp", "up") }
    static var directionDown: String { text("handlers.refusal.directionDown", "down") }
    static func needsDaemonCapability(_ capability: String) -> String { format("handlers.refusal.needsDaemonCapability", "needs daemon capability %@", capability) }
    static func updateCloudMachine(_ capability: String) -> String { format("handlers.refusal.updateCloudMachine", "update this Cloud machine to use this (its cmux-tui lacks %@)", capability) }
    static func needsAppCapability(_ feature: String) -> String { format("handlers.refusal.needsAppCapability", "needs app capability %@", feature) }
    static func notShownInAnyWindow(_ target: String) -> String { format("handlers.refusal.notShownInAnyWindow", "%@ is not shown in any window", target) }
    static var notEnoughRoomToSplit: String { text("handlers.refusal.notEnoughRoomToSplit", "not enough room to split this pane") }
    static var focusedPaneHasNoTab: String { text("handlers.refusal.focusedPaneHasNoTab", "the focused pane has no tab") }
    static func noTab(_ id: String) -> String { format("handlers.refusal.noTab", "no tab %@", id) }
    static func sessionLocalTab(_ id: String) -> String { format("handlers.refusal.sessionLocalTab", "tab %@ is session-local, not a daemon tab", id) }
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
    static var paneHasNoTabs: String { text("handlers.refusal.paneHasNoTabs", "the pane has no tabs") }
    static var tabArgumentRequired: String { text("handlers.refusal.tabArgumentRequired", "a tab argument is required") }
    static var tabAtEdge: String { text("handlers.refusal.tabAtEdge", "the tab is already at the edge") }
    static var screenHasNoOtherPane: String { text("handlers.refusal.screenHasNoOtherPane", "the screen has no other pane") }
    static func noPaneInDirectionOfTab(_ direction: String) -> String { format("handlers.refusal.noPaneInDirectionOfTab", "no pane %@ of the tab", direction) }
    static var sessionLocalCannotRename: String { text("handlers.refusal.sessionLocalCannotRename", "session-local tabs cannot be renamed") }
    static var sessionLocalHasNoName: String { text("handlers.refusal.sessionLocalHasNoName", "session-local tabs have no name") }
    static var sessionLocalCannotPin: String { text("handlers.refusal.sessionLocalCannotPin", "session-local tabs cannot be pinned") }
    static func markUnreadUnsupported(_ capability: String) -> String { format("handlers.refusal.markUnreadUnsupported", "needs daemon capability %@ (only marking read is supported)", capability) }
    static var hibernateVisibleTab: String { text("handlers.refusal.hibernateVisibleTab", "Only a hidden tab can hibernate.") }
    static var hibernateUnsupported: String {
        text("handlers.refusal.hibernateUnsupported", "This page cannot keep its history when it hibernates.")
    }
    static var wakeNotHibernated: String { text("handlers.refusal.wakeNotHibernated", "This tab is not hibernated.") }
    static var terminalCannotReload: String { text("handlers.refusal.terminalCannotReload", "terminal tabs cannot reload; use Reconnect Pane") }
    static var fullWidthTabUnported: String { text("handlers.refusal.fullWidthTabUnported", "needs full-width tab support in the cmux-next tab strip") }
    static var audioMuteUnported: String { text("handlers.refusal.audioMuteUnported", "needs audio mute support in the cmux-next browser") }
    static func noColumnShown(_ id: String) -> String { format("handlers.refusal.noColumnShown", "no column %@ is shown", id) }
    static var notColumnLayout: String { text("handlers.refusal.notColumnLayout", "the screen is not in column layout") }
    static var columnAlreadyHasWidth: String { text("handlers.refusal.columnAlreadyHasWidth", "the column already has that width") }
    static var columnTooNarrowToSplit: String { text("handlers.refusal.columnTooNarrowToSplit", "Not enough room to split this column") }
    static var columnAlreadySticky: String { text("handlers.refusal.columnAlreadySticky", "the column is already sticky there") }
    static var columnNotSticky: String { text("handlers.refusal.columnNotSticky", "the column is not sticky") }
    static var lastScrollingColumn: String { text("handlers.refusal.lastScrollingColumn", "at least one column must scroll") }
    static func noColumnInDirection(_ direction: String) -> String { format("handlers.refusal.noColumnInDirection", "no column to the %@", direction) }
    static func moveColumnUnsupported(_ capability: String, _ count: Int) -> String { format("handlers.refusal.moveColumnUnsupported", "needs daemon capability %1$@ (the column has %2$lld panes; swap-pane moves one)", capability, count) }
    static var columnAtEdge: String { text("handlers.refusal.columnAtEdge", "the column is already at the edge") }
    static func paneHasNoDaemonHandle(_ id: String) -> String { format("handlers.refusal.paneHasNoDaemonHandle", "pane %@ has no daemon handle", id) }
}
