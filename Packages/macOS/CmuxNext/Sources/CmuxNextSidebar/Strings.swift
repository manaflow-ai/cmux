import CmuxNextDesign
import Foundation

/// Localized strings. Keys live in Resources/Localizable.xcstrings (en, ja).
enum Strings {
    static func tabDropRefusal(_ reason: SidebarTabDropRefusal) -> String {
        switch reason {
        case .otherMachine:
            String(localized: "sidebar.tabDrop.otherMachine", defaultValue: "Tabs stay on their machine.", bundle: .module)
        case .pinnedArea:
            String(localized: "sidebar.tabDrop.pinnedArea", defaultValue: "The pinned area holds no new workspace.", bundle: .module)
        }
    }
    static var closeRefused: String { String(localized: "sidebar.close.refused", defaultValue: "The workspace could not be closed.", bundle: .module) }
    static var dismissCard: String { String(localized: "sidebar.card.dismiss", defaultValue: "Dismiss", bundle: .module) }
    static var newWorkspace: String { String(localized: "sidebar.newWorkspace", defaultValue: "New Workspace", bundle: .module) }
    /// The footer's Search button: its VoiceOver label and tooltip.
    static var searchButton: String { String(localized: "sidebar.search", defaultValue: "Search", bundle: .module) }
    /// The thin rail's VoiceOver label (`sidebar.style` = rail).
    static var railLabel: String { String(localized: "sidebar.rail.label", defaultValue: "Workspaces", bundle: .module) }
    static var rename: String { String(localized: "sidebar.rename", defaultValue: "Rename", bundle: .module) }
    static var pinned: String { String(localized: "sidebar.section.pinned", defaultValue: "Pinned", bundle: .module) }
    static var moveToGroup: String { String(localized: "sidebar.group.moveTo", defaultValue: "Move to Group", bundle: .module) }
    static var projects: String { String(localized: "sidebar.section.projects", defaultValue: "Projects", bundle: .module) }
    static var noFolder: String { String(localized: "sidebar.folder.none", defaultValue: "No Folder", bundle: .module) }
    static var pinnedEmpty: String { String(localized: "sidebar.section.pinned.empty", defaultValue: "Drop here to pin", bundle: .module) }
    static var sectionEmpty: String { String(localized: "sidebar.section.empty", defaultValue: "No workspaces", bundle: .module) }
    /// An open empty group's row (`EmptyGroupRowView`).
    static var groupEmpty: String { String(localized: "sidebar.group.empty", defaultValue: "No workspaces · drag one here", bundle: .module) }
    static var statusConnected: String { String(localized: "sidebar.machine.connected", defaultValue: "Connected", bundle: .module) }
    static var statusConnecting: String { String(localized: "sidebar.machine.connecting", defaultValue: "Connecting…", bundle: .module) }
    static var statusReconnecting: String { String(localized: "sidebar.machine.reconnecting", defaultValue: "Reconnecting…", bundle: .module) }
    static var statusOffline: String { String(localized: "sidebar.machine.offline", defaultValue: "Offline", bundle: .module) }
    nonisolated static func costRate(_ price: String) -> String { String(localized: "sidebar.machine.cost.rate", defaultValue: "\(price)/h", bundle: .module) }
    nonisolated static func costRateWhenRunning(_ price: String) -> String {
        String(localized: "sidebar.machine.cost.rateWhenRunning", defaultValue: "\(price)/h when running", bundle: .module)
    }
    nonisolated static func costRunning(_ duration: String) -> String { String(localized: "sidebar.machine.cost.running", defaultValue: "Running \(duration)", bundle: .module) }
    nonisolated static func costSoFar(_ price: String) -> String { String(localized: "sidebar.machine.cost.soFar", defaultValue: "About \(price) so far", bundle: .module) }
    nonisolated static func costUnderSoFar(_ price: String) -> String {
        String(localized: "sidebar.machine.cost.underSoFar", defaultValue: "Under \(price) so far", bundle: .module)
    }
    nonisolated static func capOf(_ running: Int, _ max: Int) -> String {
        String(localized: "sidebar.machine.cap.of", defaultValue: "\(running) of \(max) machines running", bundle: .module)
    }
    nonisolated static func capNone(_ running: Int) -> String {
        String(localized: "sidebar.machine.cap.none", defaultValue: "\(running) running, no machine cap", bundle: .module)
    }
    nonisolated static var capClosed: String { String(localized: "sidebar.machine.cap.closed", defaultValue: "Machines are closed on this plan", bundle: .module) }
    static var statusUpdateAvailable: String { String(localized: "sidebar.machine.updateAvailable", defaultValue: "Update available", bundle: .module) }
    static var statusUpdateRequired: String { String(localized: "sidebar.machine.updateRequired", defaultValue: "Update needed", bundle: .module) }
    static var statusInstallRequired: String { String(localized: "sidebar.machine.installRequired", defaultValue: "Install needed", bundle: .module) }
    static var statusInstalling: String { String(localized: "sidebar.machine.installing", defaultValue: "Installing…", bundle: .module) }
    static var statusAuthFailed: String { String(localized: "sidebar.machine.authFailed", defaultValue: "Sign-in failed", bundle: .module) }
    static var statusUnreachable: String { String(localized: "sidebar.machine.unreachable", defaultValue: "Unreachable", bundle: .module) }
    static var statusFailed: String { String(localized: "sidebar.machine.failed", defaultValue: "Failed to start", bundle: .module) }
    static var statusPaused: String { String(localized: "sidebar.machine.paused", defaultValue: "Paused", bundle: .module) }
    /// A Cloud machine the idle auto-pause parked (not a failure).
    static var statusPausedIdle: String { String(localized: "sidebar.machine.pausedIdle", defaultValue: "Paused (idle)", bundle: .module) }
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
        case .paused: statusPaused
        case .pausedIdle: statusPausedIdle
        case .connected, .connecting, .offline, .updateAvailable, .installing: nil
        }
    }
    static func unreadCount(_ value: Int) -> String { String(localized: "sidebar.a11y.unread", defaultValue: "\(value) unread", bundle: .module) }
    static func progressPercent(_ value: Int) -> String { String(localized: "sidebar.a11y.progress", defaultValue: "\(value)% done", bundle: .module) }
    static var showTabs: String { String(localized: "sidebar.workspace.showTabs", defaultValue: "Show Tabs", bundle: .module) }
    static var hideTabs: String { String(localized: "sidebar.workspace.hideTabs", defaultValue: "Hide Tabs", bundle: .module) }
    static func tabCount(_ value: Int) -> String { String(localized: "sidebar.a11y.tabCount", defaultValue: "Tabs: \(value)", bundle: .module) }
    /// The hover card's machine line on a workspace the Chief started for a subagent.
    /// Status entries a row folds past its limit.
    static func statusMore(_ value: Int) -> String { String(localized: "sidebar.status.more", defaultValue: "\(value) more", bundle: .module) }
    /// A listed tab's name when its own title says nothing (a bare "~", the workspace's name again).
    static var untitledTerminal: String { String(localized: "sidebar.tab.untitledTerminal", defaultValue: "Terminal", bundle: .module) }
    static var unreadDot: String { String(localized: "sidebar.a11y.unreadDot", defaultValue: "Unread", bundle: .module) }
    /// The bell-slash mark's tooltip on a muted workspace's row.
    static var notificationsMuted: String {
        String(localized: "sidebar.workspace.notificationsMuted", defaultValue: "Notifications muted", bundle: .module)
    }
    static var muteTabs: String { String(localized: "sidebar.audio.muteTabs", defaultValue: "Mute Tabs in Workspace", bundle: .module) }
    static var unmuteTabs: String { String(localized: "sidebar.audio.unmuteTabs", defaultValue: "Unmute Tabs in Workspace", bundle: .module) }
    static var activityRunning: String { String(localized: "sidebar.a11y.running", defaultValue: "Agent running", bundle: .module) }
    static var activityNeedsInput: String { String(localized: "sidebar.a11y.needsInput", defaultValue: "Needs input", bundle: .module) }
    static var activityError: String { String(localized: "sidebar.a11y.error", defaultValue: "Error", bundle: .module) }
    static var activityDone: String { String(localized: "sidebar.a11y.done", defaultValue: "Done", bundle: .module) }
    /// The line under the built-in hover card when the user's card failed to render.
    static func customCardError(_ message: String) -> String {
        String(format: String(localized: "sidebar.hoverCard.customError", defaultValue: "Custom card error: %@", bundle: .module), message)
    }
    static var activityPaused: String { String(localized: "sidebar.a11y.paused", defaultValue: "Paused", bundle: .module) }
    static func activityProgress(_ percent: Int) -> String {
        String(format: String(localized: "sidebar.a11y.progress", defaultValue: "%d%% done", bundle: .module), percent)
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
    static var closeButton: String { String(localized: "sidebar.a11y.closeWorkspace", defaultValue: "Close workspace", bundle: .module) }
    /// A listed tab row's hover close.
    static var closeTab: String { String(localized: "sidebar.a11y.closeTab", defaultValue: "Close tab", bundle: .module) }
    static var pinWorkspace: String { String(localized: "sidebar.a11y.pinWorkspace", defaultValue: "Pin workspace", bundle: .module) }
    static var unpinWorkspace: String { String(localized: "sidebar.a11y.unpinWorkspace", defaultValue: "Unpin workspace", bundle: .module) }
    /// The workspace row's more button (cx-a9h6): its menu.
    static var workspaceMenu: String { String(localized: "sidebar.a11y.workspaceMenu", defaultValue: "Workspace options", bundle: .module) }
    static func groupCount(_ value: Int) -> String { String(localized: "sidebar.a11y.groupCount", defaultValue: "\(value) workspaces", bundle: .module) }
    static var sidebarLabel: String { String(localized: "sidebar.a11y.sidebar", defaultValue: "Workspaces", bundle: .module) }
    static var newProfileName: String { String(localized: "sidebar.room.newName", defaultValue: "New Space", bundle: .module) }
    static var newProfile: String { String(localized: "sidebar.space.new", defaultValue: "New Space", bundle: .module) }
    static var profiles: String { String(localized: "sidebar.a11y.rooms", defaultValue: "Spaces", bundle: .module) }
    /// The Now Playing card's scrubber (its value says the position and the length).
    static var nowPlayingPosition: String {
        String(localized: "sidebar.a11y.nowPlaying.position", defaultValue: "Playback Position", bundle: .module)
    }
    static func profileCurrent(_ name: String) -> String {
        String(localized: "sidebar.a11y.roomCurrent", defaultValue: "\(name), current space", bundle: .module)
    }
    static var resize: String { String(localized: "sidebar.a11y.resize", defaultValue: "Resize sidebar", bundle: .module) }

    // MARK: Edit mode

    /// An item's ✕ in the sidebar's edit mode (its label and tooltip).
    static func removeItem(_ name: String) -> String {
        String(localized: "sidebar.edit.remove", defaultValue: "Remove \(name)", bundle: .module)
    }
    static var editAddItems: String { String(localized: "sidebar.edit.addItems", defaultValue: "Add Items", bundle: .module) }
    static var editDone: String { String(localized: "sidebar.edit.done", defaultValue: "Done", bundle: .module) }

    // MARK: Hover card history (u3320)

    static var timelineHeader: String { String(localized: "sidebar.hoverCard.history", defaultValue: "History", bundle: .module) }

    /// What one history line says: the prompt itself, or what the agent did.
    static func timelineText(_ entry: SidebarTimelineEntry) -> String {
        let agent = entry.agent
        switch entry.kind {
        case .prompt:
            return entry.text ?? String(localized: "sidebar.timeline.promptSent", defaultValue: "Prompt sent", bundle: .module)
        case .started:
            return agent.map { String(format: String(localized: "sidebar.timeline.startedBy", defaultValue: "%@ started working", bundle: .module), $0) }
                ?? String(localized: "sidebar.timeline.started", defaultValue: "Started working", bundle: .module)
        case .waiting:
            let base = agent.map { String(format: String(localized: "sidebar.timeline.waitingBy", defaultValue: "%@ is waiting for your input", bundle: .module), $0) }
                ?? String(localized: "sidebar.timeline.waiting", defaultValue: "Waiting for your input", bundle: .module)
            return entry.text.map { base + ": " + $0 } ?? base
        case .finished:
            return agent.map { String(format: String(localized: "sidebar.timeline.finishedBy", defaultValue: "%@ finished", bundle: .module), $0) }
                ?? String(localized: "sidebar.timeline.finished", defaultValue: "Finished", bundle: .module)
        case .failed:
            return agent.map { String(format: String(localized: "sidebar.timeline.failedBy", defaultValue: "%@ stopped with an error", bundle: .module), $0) }
                ?? String(localized: "sidebar.timeline.failed", defaultValue: "Stopped with an error", bundle: .module)
        }
    }

    /// The card's stats line: how many prompts, and how long the agents worked.
    static func timelineStats(prompts: Int, worked: String?) -> String {
        let count = String(format: String(localized: "sidebar.hoverCard.statsPrompts", defaultValue: "Prompts: %d", bundle: .module), prompts)
        guard let worked else { return count }
        return count + " · " + String(format: String(localized: "sidebar.hoverCard.statsWorked", defaultValue: "Worked %@", bundle: .module), worked)
    }
}
