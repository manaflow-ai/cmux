import CmuxNextDesign
import Foundation

/// Localized strings. Keys live in Resources/Localizable.xcstrings (en, ja).
enum Strings {
    static func tabDropRefusal(_ reason: SidebarTabDropRefusal) -> String {
        switch reason {
        case .otherMachine:
            String(localized: "sidebar.tabDrop.otherMachine", defaultValue: "Tabs stay on their machine.", bundle: .l10n)
        case .pinnedArea:
            String(localized: "sidebar.tabDrop.pinnedArea", defaultValue: "The pinned area holds no new workspace.", bundle: .l10n)
        }
    }
    static var closeRefused: String { String(localized: "sidebar.close.refused", defaultValue: "The workspace could not be closed.", bundle: .l10n) }
    static var dismissCard: String { String(localized: "sidebar.card.dismiss", defaultValue: "Dismiss", bundle: .l10n) }
    static var newWorkspace: String { String(localized: "sidebar.newWorkspace", defaultValue: "New Workspace", bundle: .l10n) }
    /// This Mac's machine header button: its tooltip and VoiceOver label.
    static var shareScreen: String { String(localized: "sidebar.machine.shareScreen", defaultValue: "Share screen", bundle: .l10n) }
    static var sharingScreen: String { String(localized: "sidebar.machine.sharingScreen", defaultValue: "Sharing screen", bundle: .l10n) }
    /// A Cloud machine or authenticated Mac header's button: its tooltip and VoiceOver label.
    static var viewScreen: String { String(localized: "sidebar.machine.viewScreen", defaultValue: "View screen", bundle: .l10n) }
    /// The chevron beside the sidebar's +: its VoiceOver label (it opens the workspace chooser).
    static var newWorkspaceOptions: String {
        String(localized: "sidebar.newWorkspace.options", defaultValue: "New Workspace Options", bundle: .l10n)
    }
    /// The footer's Search button: its VoiceOver label and tooltip.
    static var searchButton: String { String(localized: "sidebar.search", defaultValue: "Search", bundle: .l10n) }
    static var restoringDetails: String { String(localized: "sidebar.restoring.details", defaultValue: "Details", bundle: .l10n) }
    /// The thin rail's VoiceOver label (`sidebar.style` = rail).
    static var railLabel: String { String(localized: "sidebar.rail.label", defaultValue: "Workspaces", bundle: .l10n) }
    static var rename: String { String(localized: "sidebar.rename", defaultValue: "Rename", bundle: .l10n) }
    static var pinned: String { String(localized: "sidebar.section.pinned", defaultValue: "Pinned", bundle: .l10n) }
    static var moveToGroup: String { String(localized: "sidebar.group.moveTo", defaultValue: "Move to Group", bundle: .l10n) }
    static var projects: String { String(localized: "sidebar.section.projects", defaultValue: "Projects", bundle: .l10n) }
    /// Projects and Recents' header over workspaces in no group (`ListHeaderRowView`).
    static var recents: String { String(localized: "sidebar.section.recents", defaultValue: "Recents", bundle: .l10n) }
    static var noFolder: String { String(localized: "sidebar.folder.none", defaultValue: "No Folder", bundle: .l10n) }
    static var pinnedEmpty: String { String(localized: "sidebar.section.pinned.empty", defaultValue: "Drop here to pin", bundle: .l10n) }
    /// An open empty group's row (`EmptyGroupRowView`).
    static var groupEmpty: String { String(localized: "sidebar.group.empty", defaultValue: "No workspaces · drag one here", bundle: .l10n) }
    static var statusConnected: String { String(localized: "sidebar.machine.connected", defaultValue: "Connected", bundle: .l10n) }
    static var statusConnecting: String { String(localized: "sidebar.machine.connecting", defaultValue: "Connecting…", bundle: .l10n) }
    static var statusReconnecting: String { String(localized: "sidebar.machine.reconnecting", defaultValue: "Reconnecting…", bundle: .l10n) }
    static var statusOffline: String { String(localized: "sidebar.machine.offline", defaultValue: "Offline", bundle: .l10n) }
    nonisolated static func costRate(_ price: String) -> String { String(localized: "sidebar.machine.cost.rate", defaultValue: "\(price)/h", bundle: .l10n) }
    nonisolated static func costRateWhenRunning(_ price: String) -> String {
        String(localized: "sidebar.machine.cost.rateWhenRunning", defaultValue: "\(price)/h when running", bundle: .l10n)
    }
    nonisolated static func costRunning(_ duration: String) -> String { String(localized: "sidebar.machine.cost.running", defaultValue: "Running \(duration)", bundle: .l10n) }
    nonisolated static func costSoFar(_ price: String) -> String { String(localized: "sidebar.machine.cost.soFar", defaultValue: "About \(price) so far", bundle: .l10n) }
    nonisolated static func costUnderSoFar(_ price: String) -> String {
        String(localized: "sidebar.machine.cost.underSoFar", defaultValue: "Under \(price) so far", bundle: .l10n)
    }
    nonisolated static func capOf(_ running: Int, _ max: Int) -> String {
        String(localized: "sidebar.machine.cap.of", defaultValue: "\(running) of \(max) machines running", bundle: .l10n)
    }
    nonisolated static func capNone(_ running: Int) -> String {
        String(localized: "sidebar.machine.cap.none", defaultValue: "\(running) running, no machine cap", bundle: .l10n)
    }
    nonisolated static var capClosed: String { String(localized: "sidebar.machine.cap.closed", defaultValue: "Machines are closed on this plan", bundle: .l10n) }
    static var statusUpdateAvailable: String { String(localized: "sidebar.machine.updateAvailable", defaultValue: "Update available", bundle: .l10n) }
    static var statusUpdateRequired: String { String(localized: "sidebar.machine.updateRequired", defaultValue: "Update needed", bundle: .l10n) }
    static var statusInstallRequired: String { String(localized: "sidebar.machine.installRequired", defaultValue: "Install needed", bundle: .l10n) }
    static var statusInstalling: String { String(localized: "sidebar.machine.installing", defaultValue: "Installing…", bundle: .l10n) }
    static var statusAuthFailed: String { String(localized: "sidebar.machine.authFailed", defaultValue: "Sign-in failed", bundle: .l10n) }
    static var statusUnreachable: String { String(localized: "sidebar.machine.unreachable", defaultValue: "Unreachable", bundle: .l10n) }
    static var statusFailed: String { String(localized: "sidebar.machine.failed", defaultValue: "Failed to start", bundle: .l10n) }
    /// A Cloud machine that ran and lost its link (not one that failed to start).
    static var statusDisconnected: String { String(localized: "sidebar.machine.disconnected", defaultValue: "Disconnected", bundle: .l10n) }
    static var statusPaused: String { String(localized: "sidebar.machine.paused", defaultValue: "Paused", bundle: .l10n) }
    /// A Cloud machine the idle auto-pause parked (not a failure).
    static var statusPausedIdle: String { String(localized: "sidebar.machine.pausedIdle", defaultValue: "Paused (idle)", bundle: .l10n) }
    /// A Cloud machine on its way to paused, running again or deleted.
    static var statusPausing: String { String(localized: "sidebar.machine.pausing", defaultValue: "Pausing…", bundle: .l10n) }
    static var statusResuming: String { String(localized: "sidebar.machine.resuming", defaultValue: "Resuming…", bundle: .l10n) }
    static var statusDeleting: String { String(localized: "sidebar.machine.deleting", defaultValue: "Deleting…", bundle: .l10n) }
    /// The status of a computer that cannot connect until the person acts,
    /// nil otherwise: its workspace rows name it in one list (cx-mdo0). A
    /// paused machine is named too (it resumes on attach, nothing to fix).
    static func attentionStatus(_ status: SidebarMachine.Status) -> String? {
        switch status {
        case .authFailed: statusAuthFailed
        case .unreachable: statusUnreachable
        case .reconnecting: statusReconnecting
        case .installRequired: statusInstallRequired
        case .updateRequired: statusUpdateRequired
        case .failed: statusFailed
        case .disconnected: statusDisconnected
        case .paused: statusPaused
        case .pausedIdle: statusPausedIdle
        case .pausing: statusPausing
        case .resuming: statusResuming
        case .deleting: statusDeleting
        case .connecting: statusConnecting
        case .connected, .offline, .updateAvailable, .installing: nil
        }
    }
    static func unreadCount(_ value: Int) -> String { String(localized: "sidebar.a11y.unread", defaultValue: "\(value) unread", bundle: .l10n) }
    static func progressPercent(_ value: Int) -> String { String(localized: "sidebar.a11y.progress", defaultValue: "\(value)% done", bundle: .l10n) }
    /// The hover card's line for a workspace whose idle terminals were freed (`workspaces.freeing.*`).
    static func freedTerminals(_ value: Int) -> String { String(localized: "sidebar.hoverCard.freedTerminals", defaultValue: "Freed terminals: \(value). They start again when you open this workspace.", bundle: .l10n) }
    static func tabCount(_ value: Int) -> String { String(localized: "sidebar.a11y.tabCount", defaultValue: "Tabs: \(value)", bundle: .l10n) }
    /// The hover card's machine line on a workspace the Chief started for a subagent.
    /// Status entries a row folds past its limit.
    static func statusMore(_ value: Int) -> String { String(localized: "sidebar.status.more", defaultValue: "\(value) more", bundle: .l10n) }
    static var unreadDot: String { String(localized: "sidebar.a11y.unreadDot", defaultValue: "Unread", bundle: .l10n) }
    /// The bell-slash mark's tooltip on a muted workspace's row.
    static var notificationsMuted: String {
        String(localized: "sidebar.workspace.notificationsMuted", defaultValue: "Notifications muted", bundle: .l10n)
    }
    static var muteTabs: String { String(localized: "sidebar.audio.muteTabs", defaultValue: "Mute Tabs in Workspace", bundle: .l10n) }
    static var unmuteTabs: String { String(localized: "sidebar.audio.unmuteTabs", defaultValue: "Unmute Tabs in Workspace", bundle: .l10n) }
    static var activityRunning: String { String(localized: "sidebar.a11y.running", defaultValue: "Agent running", bundle: .l10n) }
    static var activityNeedsInput: String { String(localized: "sidebar.a11y.needsInput", defaultValue: "Needs input", bundle: .l10n) }
    static var activityError: String { String(localized: "sidebar.a11y.error", defaultValue: "Error", bundle: .l10n) }
    static var activityDone: String { String(localized: "sidebar.a11y.done", defaultValue: "Done", bundle: .l10n) }
    /// The line under the built-in hover card when the user's card failed to render.
    static func customCardError(_ message: String) -> String {
        String(format: String(localized: "sidebar.hoverCard.customError", defaultValue: "Custom card error: %@", bundle: .l10n), message)
    }
    static var activityPaused: String { String(localized: "sidebar.a11y.paused", defaultValue: "Paused", bundle: .l10n) }
    static func activityProgress(_ percent: Int) -> String {
        String(format: String(localized: "sidebar.a11y.progress", defaultValue: "%d%% done", bundle: .l10n), percent)
    }

    /// Spoken status of a row's indicator, nil when idle.
    static func activity(_ state: StatusIndicatorState) -> String? {
        switch state {
        case .idle: nil
        case .busy, .working: state.progress.map { activityProgress(Int(($0 * 100).rounded())) } ?? activityRunning
        case .paused: activityPaused
        case .waiting: activityNeedsInput
        case .error: activityError
        case .success: activityDone
        }
    }
    static var closeButton: String { String(localized: "sidebar.a11y.closeWorkspace", defaultValue: "Close workspace", bundle: .l10n) }
    static var pinWorkspace: String { String(localized: "sidebar.a11y.pinWorkspace", defaultValue: "Pin workspace", bundle: .l10n) }
    static var unpinWorkspace: String { String(localized: "sidebar.a11y.unpinWorkspace", defaultValue: "Unpin workspace", bundle: .l10n) }
    /// The workspace row's more button (cx-a9h6): its menu.
    static var workspaceMenu: String { String(localized: "sidebar.a11y.workspaceMenu", defaultValue: "Workspace options", bundle: .l10n) }
    static func groupCount(_ value: Int) -> String { String(localized: "sidebar.a11y.groupCount", defaultValue: "\(value) workspaces", bundle: .l10n) }
    static var sidebarLabel: String { String(localized: "sidebar.a11y.sidebar", defaultValue: "Workspaces", bundle: .l10n) }
    static var newProfileName: String { String(localized: "sidebar.room.newName", defaultValue: "New Space", bundle: .l10n) }
    static var newProfile: String { String(localized: "sidebar.space.new", defaultValue: "New Space", bundle: .l10n) }
    static var profiles: String { String(localized: "sidebar.a11y.rooms", defaultValue: "Spaces", bundle: .l10n) }
    // The switcher's window marks (design/spaces.md "The switcher (PR 3)").
    static var goToSpaceWindow: String { String(localized: "sidebar.space.goToWindow", defaultValue: "Switch to That Window", bundle: .l10n) }
    static var moveSpaceHere: String { String(localized: "sidebar.space.moveHere", defaultValue: "Move to This Window", bundle: .l10n) }
    static var newIncognitoSpace: String { String(localized: "sidebar.space.newIncognito", defaultValue: "New Incognito Space", bundle: .l10n) }
    static func spaceInAnotherWindow(_ name: String) -> String {
        String(localized: "sidebar.space.inAnotherWindow", defaultValue: "\(name), in another window", bundle: .l10n)
    }
    /// The Now Playing card's scrubber (its value says the position and the length).
    static var nowPlayingPosition: String {
        String(localized: "sidebar.a11y.nowPlaying.position", defaultValue: "Playback Position", bundle: .l10n)
    }
    static func profileCurrent(_ name: String) -> String {
        String(localized: "sidebar.a11y.roomCurrent", defaultValue: "\(name), current space", bundle: .l10n)
    }
    static var resize: String { String(localized: "sidebar.a11y.resize", defaultValue: "Resize sidebar", bundle: .l10n) }

    // MARK: Edit mode

    /// An item's ✕ in the sidebar's edit mode (its label and tooltip).
    static func removeItem(_ name: String) -> String {
        String(localized: "sidebar.edit.remove", defaultValue: "Remove \(name)", bundle: .l10n)
    }
    static var editAddItems: String { String(localized: "sidebar.edit.addItems", defaultValue: "Add Items", bundle: .l10n) }
    static var editDone: String { String(localized: "sidebar.edit.done", defaultValue: "Done", bundle: .l10n) }

    // MARK: Hover card history (u3320)

    static var timelineHeader: String { String(localized: "sidebar.hoverCard.history", defaultValue: "History", bundle: .l10n) }

    /// What one history line says: the prompt itself, or what the agent did.
    static func timelineText(_ entry: SidebarTimelineEntry) -> String {
        let agent = entry.agent
        switch entry.kind {
        case .prompt:
            return entry.text ?? String(localized: "sidebar.timeline.promptSent", defaultValue: "Prompt sent", bundle: .l10n)
        case .started:
            return agent.map { String(format: String(localized: "sidebar.timeline.startedBy", defaultValue: "%@ started working", bundle: .l10n), $0) }
                ?? String(localized: "sidebar.timeline.started", defaultValue: "Started working", bundle: .l10n)
        case .waiting:
            let base = agent.map { String(format: String(localized: "sidebar.timeline.waitingBy", defaultValue: "%@ is waiting for your input", bundle: .l10n), $0) }
                ?? String(localized: "sidebar.timeline.waiting", defaultValue: "Waiting for your input", bundle: .l10n)
            return entry.text.map { base + ": " + $0 } ?? base
        case .finished:
            return agent.map { String(format: String(localized: "sidebar.timeline.finishedBy", defaultValue: "%@ finished", bundle: .l10n), $0) }
                ?? String(localized: "sidebar.timeline.finished", defaultValue: "Finished", bundle: .l10n)
        case .failed:
            return agent.map { String(format: String(localized: "sidebar.timeline.failedBy", defaultValue: "%@ stopped with an error", bundle: .l10n), $0) }
                ?? String(localized: "sidebar.timeline.failed", defaultValue: "Stopped with an error", bundle: .l10n)
        }
    }

    /// The usage row's parts: the tokens each call carries ("312K context") and the last 24
    /// hours' cost ("$1,421 in 24h").
    static func usageContext(_ tokens: String) -> String {
        String(format: String(localized: "sidebar.hoverCard.usageContext", defaultValue: "%@ context", bundle: .l10n), tokens)
    }
    static func usageCost(_ cost: String) -> String {
        String(format: String(localized: "sidebar.hoverCard.usageCost", defaultValue: "%@ in 24h", bundle: .l10n), cost)
    }

    /// The card's stats line: how many prompts, and how long the agents worked.
    static func timelineStats(prompts: Int, worked: String?) -> String {
        let count = String(format: String(localized: "sidebar.hoverCard.statsPrompts", defaultValue: "Prompts: %d", bundle: .l10n), prompts)
        guard let worked else { return count }
        return count + " · " + String(format: String(localized: "sidebar.hoverCard.statsWorked", defaultValue: "Worked %@", bundle: .l10n), worked)
    }
}
