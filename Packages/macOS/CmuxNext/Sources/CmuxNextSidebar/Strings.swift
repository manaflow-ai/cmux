import CmuxNextDesign
import Foundation

/// Localized strings. Keys live in Resources/Localizable.xcstrings (en, ja).
enum Strings {
    static func tabDropRefusal(_ reason: SidebarTabDropRefusal) -> String {
        switch reason {
        case .otherMachine:
            String(localized: "sidebar.tabDrop.otherMachine", defaultValue: "Tabs stay on their machine.", bundle: .localizedModule)
        case .pinnedArea:
            String(localized: "sidebar.tabDrop.pinnedArea", defaultValue: "The pinned area holds no new workspace.", bundle: .localizedModule)
        }
    }
    static var closeRefused: String { String(localized: "sidebar.close.refused", defaultValue: "The workspace could not be closed.", bundle: .localizedModule) }
    static var dismissCard: String { String(localized: "sidebar.card.dismiss", defaultValue: "Dismiss", bundle: .localizedModule) }
    static var newWorkspace: String { String(localized: "sidebar.newWorkspace", defaultValue: "New Workspace", bundle: .localizedModule) }
    /// This Mac's machine header button: its tooltip and VoiceOver label.
    static var shareScreen: String { String(localized: "sidebar.machine.shareScreen", defaultValue: "Share screen", bundle: .localizedModule) }
    static var sharingScreen: String { String(localized: "sidebar.machine.sharingScreen", defaultValue: "Sharing screen", bundle: .localizedModule) }
    /// A Cloud machine or authenticated Mac header's button: its tooltip and VoiceOver label.
    static var viewScreen: String { String(localized: "sidebar.machine.viewScreen", defaultValue: "View screen", bundle: .localizedModule) }
    /// The chevron beside the sidebar's +: its VoiceOver label (it opens the workspace chooser).
    static var newWorkspaceOptions: String {
        String(localized: "sidebar.newWorkspace.options", defaultValue: "New Workspace Options", bundle: .localizedModule)
    }
    /// The footer's Search button: its VoiceOver label and tooltip.
    static var searchButton: String { String(localized: "sidebar.search", defaultValue: "Search", bundle: .localizedModule) }
    static var restoringDetails: String { String(localized: "sidebar.restoring.details", defaultValue: "Details", bundle: .localizedModule) }
    /// The thin rail's VoiceOver label (`sidebar.style` = rail).
    static var railLabel: String { String(localized: "sidebar.rail.label", defaultValue: "Workspaces", bundle: .localizedModule) }
    static var rename: String { String(localized: "sidebar.rename", defaultValue: "Rename", bundle: .localizedModule) }
    static var pinned: String { String(localized: "sidebar.section.pinned", defaultValue: "Pinned", bundle: .localizedModule) }
    static var moveToGroup: String { String(localized: "sidebar.group.moveTo", defaultValue: "Move to Group", bundle: .localizedModule) }
    static var projects: String { String(localized: "sidebar.section.projects", defaultValue: "Projects", bundle: .localizedModule) }
    /// Projects and Recents' header over workspaces in no group (`ListHeaderRowView`).
    static var recents: String { String(localized: "sidebar.section.recents", defaultValue: "Recents", bundle: .localizedModule) }
    static var noFolder: String { String(localized: "sidebar.folder.none", defaultValue: "No Folder", bundle: .localizedModule) }
    /// An open empty group's row (`EmptyGroupRowView`).
    static var groupEmpty: String { String(localized: "sidebar.group.empty", defaultValue: "No workspaces · drag one here", bundle: .localizedModule) }
    static var statusConnected: String { String(localized: "sidebar.machine.connected", defaultValue: "Connected", bundle: .localizedModule) }
    static var statusConnecting: String { String(localized: "sidebar.machine.connecting", defaultValue: "Connecting…", bundle: .localizedModule) }
    static var statusReconnecting: String { String(localized: "sidebar.machine.reconnecting", defaultValue: "Reconnecting…", bundle: .localizedModule) }
    static var statusOffline: String { String(localized: "sidebar.machine.offline", defaultValue: "Offline", bundle: .localizedModule) }
    nonisolated static func costRate(_ price: String) -> String { String(localized: "sidebar.machine.cost.rate", defaultValue: "\(price)/h", bundle: .localizedModule) }
    nonisolated static func costRateWhenRunning(_ price: String) -> String {
        String(localized: "sidebar.machine.cost.rateWhenRunning", defaultValue: "\(price)/h when running", bundle: .localizedModule)
    }
    nonisolated static func costRunning(_ duration: String) -> String { String(localized: "sidebar.machine.cost.running", defaultValue: "Running \(duration)", bundle: .localizedModule) }
    nonisolated static func costSoFar(_ price: String) -> String { String(localized: "sidebar.machine.cost.soFar", defaultValue: "About \(price) so far", bundle: .localizedModule) }
    nonisolated static func costUnderSoFar(_ price: String) -> String {
        String(localized: "sidebar.machine.cost.underSoFar", defaultValue: "Under \(price) so far", bundle: .localizedModule)
    }
    nonisolated static func capOf(_ running: Int, _ max: Int) -> String {
        String(localized: "sidebar.machine.cap.of", defaultValue: "\(running) of \(max) machines running", bundle: .localizedModule)
    }
    nonisolated static func capNone(_ running: Int) -> String {
        String(localized: "sidebar.machine.cap.none", defaultValue: "\(running) running, no machine cap", bundle: .localizedModule)
    }
    nonisolated static var capClosed: String { String(localized: "sidebar.machine.cap.closed", defaultValue: "Machines are closed on this plan", bundle: .localizedModule) }
    static var statusUpdateAvailable: String { String(localized: "sidebar.machine.updateAvailable", defaultValue: "Update available", bundle: .localizedModule) }
    static var statusUpdateRequired: String { String(localized: "sidebar.machine.updateRequired", defaultValue: "Update needed", bundle: .localizedModule) }
    static var statusInstallRequired: String { String(localized: "sidebar.machine.installRequired", defaultValue: "Install needed", bundle: .localizedModule) }
    static var statusInstalling: String { String(localized: "sidebar.machine.installing", defaultValue: "Installing…", bundle: .localizedModule) }
    static var statusAuthFailed: String { String(localized: "sidebar.machine.authFailed", defaultValue: "Sign-in failed", bundle: .localizedModule) }
    static var statusUnreachable: String { String(localized: "sidebar.machine.unreachable", defaultValue: "Unreachable", bundle: .localizedModule) }
    static var statusFailed: String { String(localized: "sidebar.machine.failed", defaultValue: "Failed to start", bundle: .localizedModule) }
    /// A Cloud machine that ran and lost its link (not one that failed to start).
    static var statusDisconnected: String { String(localized: "sidebar.machine.disconnected", defaultValue: "Disconnected", bundle: .localizedModule) }
    static var statusPaused: String { String(localized: "sidebar.machine.paused", defaultValue: "Paused", bundle: .localizedModule) }
    /// A Cloud machine the idle auto-pause parked (not a failure).
    static var statusPausedIdle: String { String(localized: "sidebar.machine.pausedIdle", defaultValue: "Paused (idle)", bundle: .localizedModule) }
    /// A Cloud machine on its way to paused, running again or deleted.
    static var statusPausing: String { String(localized: "sidebar.machine.pausing", defaultValue: "Pausing…", bundle: .localizedModule) }
    static var statusResuming: String { String(localized: "sidebar.machine.resuming", defaultValue: "Resuming…", bundle: .localizedModule) }
    static var statusDeleting: String { String(localized: "sidebar.machine.deleting", defaultValue: "Deleting…", bundle: .localizedModule) }
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
    static func unreadCount(_ value: Int) -> String { String(localized: "sidebar.a11y.unread", defaultValue: "\(value) unread", bundle: .localizedModule) }
    static func progressPercent(_ value: Int) -> String { String(localized: "sidebar.a11y.progress", defaultValue: "\(value)% done", bundle: .localizedModule) }
    /// The agent chat's task list: steps done of all (the row's "3/7" in words, and the hover card's line).
    static func taskProgress(done: Int, total: Int) -> String {
        String(localized: "sidebar.tasks.progress", defaultValue: "\(done) of \(total) tasks done", bundle: .localizedModule)
    }
    /// The hover card's line for the step the agent works on.
    static func taskNow(_ step: String) -> String { String(localized: "sidebar.tasks.now", defaultValue: "Now: \(step)", bundle: .localizedModule) }
    /// The hover card's line for the step after it.
    static func taskNext(_ step: String) -> String { String(localized: "sidebar.tasks.next", defaultValue: "Next: \(step)", bundle: .localizedModule) }
    /// The hover card's line for a workspace whose idle terminals were freed (`workspaces.freeing.*`).
    static func freedTerminals(_ value: Int) -> String { String(localized: "sidebar.hoverCard.freedTerminals", defaultValue: "Freed terminals: \(value). They start again when you open this workspace.", bundle: .localizedModule) }
    /// The hover card's split miniature, for VoiceOver.
    static func paneCount(_ value: Int) -> String { String(localized: "sidebar.a11y.paneCount", defaultValue: "Panes: \(value)", bundle: .localizedModule) }
    static func tabCount(_ value: Int) -> String { String(localized: "sidebar.a11y.tabCount", defaultValue: "Tabs: \(value)", bundle: .localizedModule) }
    /// The hover card's machine line on a workspace the Chief started for a subagent.
    /// Status entries a row folds past its limit.
    static func statusMore(_ value: Int) -> String { String(localized: "sidebar.status.more", defaultValue: "\(value) more", bundle: .localizedModule) }
    static var unreadDot: String { String(localized: "sidebar.a11y.unreadDot", defaultValue: "Unread", bundle: .localizedModule) }
    /// An agent's given name with the one it had before (the hover card's agent line): "Mango — fka claude-sr2-coord".
    static func formerlyKnownAs(_ name: String, former: String) -> String {
        String(localized: "sidebar.workspace.formerlyKnownAs", defaultValue: "\(name) — fka \(former)", bundle: .localizedModule)
    }
    /// The bell-slash mark's tooltip on a muted workspace's row.
    static var notificationsMuted: String {
        String(localized: "sidebar.workspace.notificationsMuted", defaultValue: "Notifications muted", bundle: .localizedModule)
    }
    static var muteTabs: String { String(localized: "sidebar.audio.muteTabs", defaultValue: "Mute Tabs in Workspace", bundle: .localizedModule) }
    static var unmuteTabs: String { String(localized: "sidebar.audio.unmuteTabs", defaultValue: "Unmute Tabs in Workspace", bundle: .localizedModule) }
    static var activityRunning: String { String(localized: "sidebar.a11y.running", defaultValue: "Agent running", bundle: .localizedModule) }
    static var activityNeedsInput: String { String(localized: "sidebar.a11y.needsInput", defaultValue: "Needs input", bundle: .localizedModule) }
    static var activityError: String { String(localized: "sidebar.a11y.error", defaultValue: "Error", bundle: .localizedModule) }
    static var activityDone: String { String(localized: "sidebar.a11y.done", defaultValue: "Done", bundle: .localizedModule) }
    /// The line under the built-in hover card when the user's card failed to render.
    static func customCardError(_ message: String) -> String {
        String(format: String(localized: "sidebar.hoverCard.customError", defaultValue: "Custom card error: %@", bundle: .localizedModule), message)
    }
    static var activityPaused: String { String(localized: "sidebar.a11y.paused", defaultValue: "Paused", bundle: .localizedModule) }
    static func activityProgress(_ percent: Int) -> String {
        String(format: String(localized: "sidebar.a11y.progress", defaultValue: "%d%% done", bundle: .localizedModule), percent)
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
    static var closeButton: String { String(localized: "sidebar.a11y.closeWorkspace", defaultValue: "Close workspace", bundle: .localizedModule) }
    static var pinWorkspace: String { String(localized: "sidebar.a11y.pinWorkspace", defaultValue: "Pin workspace", bundle: .localizedModule) }
    static var unpinWorkspace: String { String(localized: "sidebar.a11y.unpinWorkspace", defaultValue: "Unpin workspace", bundle: .localizedModule) }
    /// The workspace row's more button (cx-a9h6): its menu.
    static var workspaceMenu: String { String(localized: "sidebar.a11y.workspaceMenu", defaultValue: "Workspace options", bundle: .localizedModule) }
    static func groupCount(_ value: Int) -> String { String(localized: "sidebar.a11y.groupCount", defaultValue: "\(value) workspaces", bundle: .localizedModule) }
    static var sidebarLabel: String { String(localized: "sidebar.a11y.sidebar", defaultValue: "Workspaces", bundle: .localizedModule) }
    static var newProfileName: String { String(localized: "sidebar.room.newName", defaultValue: "New Space", bundle: .localizedModule) }
    static var newProfile: String { String(localized: "sidebar.space.new", defaultValue: "New Space", bundle: .localizedModule) }
    static var profiles: String { String(localized: "sidebar.a11y.rooms", defaultValue: "Spaces", bundle: .localizedModule) }
    // The switcher's window marks (design/spaces.md "The switcher (PR 3)").
    static var goToSpaceWindow: String { String(localized: "sidebar.space.goToWindow", defaultValue: "Switch to That Window", bundle: .localizedModule) }
    static var moveSpaceHere: String { String(localized: "sidebar.space.moveHere", defaultValue: "Move to This Window", bundle: .localizedModule) }
    static var newIncognitoSpace: String { String(localized: "sidebar.space.newIncognito", defaultValue: "New Incognito Space", bundle: .localizedModule) }
    static func spaceInAnotherWindow(_ name: String) -> String {
        String(localized: "sidebar.space.inAnotherWindow", defaultValue: "\(name), in another window", bundle: .localizedModule)
    }
    /// The Now Playing card's scrubber (its value says the position and the length).
    static var nowPlayingPosition: String {
        String(localized: "sidebar.a11y.nowPlaying.position", defaultValue: "Playback Position", bundle: .localizedModule)
    }
    static func profileCurrent(_ name: String) -> String {
        String(localized: "sidebar.a11y.roomCurrent", defaultValue: "\(name), current space", bundle: .localizedModule)
    }
    static var resize: String { String(localized: "sidebar.a11y.resize", defaultValue: "Resize sidebar", bundle: .localizedModule) }

    // MARK: Edit mode

    /// An item's ✕ in the sidebar's edit mode (its label and tooltip).
    static func removeItem(_ name: String) -> String {
        String(localized: "sidebar.edit.remove", defaultValue: "Remove \(name)", bundle: .localizedModule)
    }
    static var editAddItems: String { String(localized: "sidebar.edit.addItems", defaultValue: "Add Items", bundle: .localizedModule) }
    static var editDone: String { String(localized: "sidebar.edit.done", defaultValue: "Done", bundle: .localizedModule) }

    // MARK: Hover card history (u3320)

    static var timelineHeader: String { String(localized: "sidebar.hoverCard.history", defaultValue: "History", bundle: .localizedModule) }

    /// What one history line says: the prompt itself, or what the agent did.
    static func timelineText(_ entry: SidebarTimelineEntry) -> String {
        let agent = entry.agent
        switch entry.kind {
        case .prompt:
            return entry.text ?? String(localized: "sidebar.timeline.promptSent", defaultValue: "Prompt sent", bundle: .localizedModule)
        case .started:
            return agent.map { String(format: String(localized: "sidebar.timeline.startedBy", defaultValue: "%@ started working", bundle: .localizedModule), $0) }
                ?? String(localized: "sidebar.timeline.started", defaultValue: "Started working", bundle: .localizedModule)
        case .waiting:
            let base = agent.map { String(format: String(localized: "sidebar.timeline.waitingBy", defaultValue: "%@ is waiting for your input", bundle: .localizedModule), $0) }
                ?? String(localized: "sidebar.timeline.waiting", defaultValue: "Waiting for your input", bundle: .localizedModule)
            return entry.text.map { base + ": " + $0 } ?? base
        case .finished:
            return agent.map { String(format: String(localized: "sidebar.timeline.finishedBy", defaultValue: "%@ finished", bundle: .localizedModule), $0) }
                ?? String(localized: "sidebar.timeline.finished", defaultValue: "Finished", bundle: .localizedModule)
        case .failed:
            return agent.map { String(format: String(localized: "sidebar.timeline.failedBy", defaultValue: "%@ stopped with an error", bundle: .localizedModule), $0) }
                ?? String(localized: "sidebar.timeline.failed", defaultValue: "Stopped with an error", bundle: .localizedModule)
        }
    }

    /// The usage row's parts: the tokens each call carries ("312K context") and the last 24
    /// hours' cost ("$1,421 in 24h").
    static func usageContext(_ tokens: String) -> String {
        String(format: String(localized: "sidebar.hoverCard.usageContext", defaultValue: "%@ context", bundle: .localizedModule), tokens)
    }
    static func usageCost(_ cost: String) -> String {
        String(format: String(localized: "sidebar.hoverCard.usageCost", defaultValue: "%@ in 24h", bundle: .localizedModule), cost)
    }

    /// The card's stats line: how many prompts, and how long the agents worked.
    static func timelineStats(prompts: Int, worked: String?) -> String {
        let count = String(format: String(localized: "sidebar.hoverCard.statsPrompts", defaultValue: "Prompts: %d", bundle: .localizedModule), prompts)
        guard let worked else { return count }
        return count + " · " + String(format: String(localized: "sidebar.hoverCard.statsWorked", defaultValue: "Worked %@", bundle: .localizedModule), worked)
    }
}
