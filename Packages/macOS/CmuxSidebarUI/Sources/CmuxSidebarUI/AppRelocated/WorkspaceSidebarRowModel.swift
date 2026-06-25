import AppKit
import Combine
import CmuxFoundation
import CmuxSettings
import CmuxSidebar
import CmuxSidebarUI
import SwiftUI

/// App-side host for one sidebar workspace row. Owns every app-coupled
/// computation the lifted ``CmuxSidebarUI.TabItemView`` row deliberately does
/// not: building the workspace snapshot from the live `Workspace`, the
/// context-menu data/actions, the resolved row appearance, and the action
/// handlers (selection, reorder, close, color, rename, window moves). The row
/// view itself holds only the value snapshots and closures this model produces,
/// keeping it on the package side of the LazyVStack snapshot boundary.
///
/// This is the "thin adapter + value-snapshot mount" the row contract calls for:
/// the model reads `tabManager`/`notificationStore`/`tab` (the parent owns those
/// stores); the row never does.
@MainActor
struct WorkspaceSidebarRowModel {
    static let workspaceObservationCoalesceInterval: RunLoop.SchedulerTimeType.Stride = .milliseconds(40)
    private static let legacyVMWebSocketDescription = "VM WebSocket PTY"

#if DEBUG
    static let sidebarDescriptionDebugLog: ((_ phase: String, _ markdown: String) -> Void)? = { phase, value in
        let workspaceState = phase == "appear" ? "appear" : "change"
        let newlineCount = value.reduce(into: 0) { count, character in
            if character == "\n" { count += 1 }
        }
        cmuxDebugLog(
            "sidebar.description.render workspaceState=\(workspaceState) " +
            "len=\((value as NSString).length) " +
            "newlines=\(newlineCount) " +
            "text=\"\((value).commandPaletteDebugPreview())\""
        )
    }
#else
    static let sidebarDescriptionDebugLog: ((_ phase: String, _ markdown: String) -> Void)? = nil
#endif

    let tabManager: TabManager
    let notificationStore: TerminalNotificationStore
    let tab: Workspace
    let index: Int
    let isActive: Bool
    let accessibilityWorkspaceCount: Int
    let rowSpacing: CGFloat
    let setSelectionToTabs: () -> Void
    let selectedTabIds: Binding<Set<UUID>>
    let lastSidebarSelectionIndex: Binding<Int?>
    let contextMenuWorkspaceIds: [UUID]
    let remoteContextMenuWorkspaceIds: [UUID]
    let allRemoteContextMenuTargetsConnecting: Bool
    let allRemoteContextMenuTargetsDisconnected: Bool
    let contextMenuPinState: WorkspaceActionDispatcher.PinState?
    let workspaceGroupMenuSnapshot: WorkspaceGroupMenuSnapshot
    let settings: TabItemSettingsSnapshot
    /// The color scheme used to resolve appearance. The row re-derives the model
    /// per render with the live scheme via ``withColorScheme(_:)`` so selection
    /// color overrides track light/dark changes.
    var colorScheme: ColorScheme = .light

    private static let maxWrappedTitleLines = 8
    private static let maxDisplayedTitleCharacters = 2048

    func withColorScheme(_ colorScheme: ColorScheme) -> WorkspaceSidebarRowModel {
        var copy = self
        copy.colorScheme = colorScheme
        return copy
    }

    // MARK: - Settings accessors

    private var sidebarShowGitBranch: Bool { settings.showsGitBranch }
    private var sidebarBranchVerticalLayout: Bool { settings.usesVerticalBranchLayout }
    private var sidebarUsesLastSegmentPath: Bool { settings.usesLastSegmentPath }
    private var sidebarShowSSH: Bool { settings.showsSSH }
    private var visibleAuxiliaryDetails: SidebarWorkspaceAuxiliaryDetailVisibility { settings.visibleAuxiliaryDetails }
    private var activeTabIndicatorStyle: WorkspaceIndicatorStyle { settings.activeTabIndicatorStyle }
    private var sidebarSelectionColorHex: String? { settings.selectionColorHex }
    private var sidebarNotificationBadgeColorHex: String? { settings.notificationBadgeColorHex }
    private var openSidebarPullRequestLinksInCmuxBrowser: Bool { settings.openPullRequestLinksInCmuxBrowser }
    private var openSidebarPortLinksInCmuxBrowser: Bool { settings.openPortLinksInCmuxBrowser }
    private var fontScale: CGFloat { settings.sidebarFontScale }

    private var isMultiSelected: Bool {
        selectedTabIds.wrappedValue.contains(tab.id)
    }

    // MARK: - Colors (resolved appearance)

    private var selectedWorkspaceBackgroundNSColor: NSColor {
        sidebarSelectedWorkspaceBackgroundNSColor(
            for: colorScheme,
            sidebarSelectionColorHex: sidebarSelectionColorHex
        )
    }

    private func selectedWorkspaceForegroundNSColor(opacity: CGFloat) -> NSColor {
        sidebarSelectedWorkspaceForegroundNSColor(
            on: selectedWorkspaceBackgroundNSColor,
            opacity: opacity
        )
    }

    private var usesInvertedActiveForeground: Bool { isActive }

    private var activePrimaryTextColor: Color {
        usesInvertedActiveForeground
            ? Color(nsColor: selectedWorkspaceForegroundNSColor(opacity: 1.0))
            : .primary
    }

    private func activeSecondaryColor(_ opacity: Double = 0.75) -> Color {
        usesInvertedActiveForeground
            ? Color(nsColor: selectedWorkspaceForegroundNSColor(opacity: CGFloat(opacity)))
            : .secondary
    }

    private var activeUnreadBadgeFillColor: Color {
        if let hex = sidebarNotificationBadgeColorHex, let nsColor = NSColor(hex: hex) {
            return Color(nsColor: nsColor)
        }
        return usesInvertedActiveForeground ? activePrimaryTextColor.opacity(0.25) : cmuxAccentColor()
    }

    private var activeUnreadBadgeTextColor: Color {
        usesInvertedActiveForeground ? activePrimaryTextColor : .white
    }

    private var activeProgressTrackColor: Color {
        usesInvertedActiveForeground ? activeSecondaryColor(0.15) : Color.secondary.opacity(0.2)
    }

    private var activeProgressFillColor: Color {
        usesInvertedActiveForeground ? activeSecondaryColor(0.8) : cmuxAccentColor()
    }

    private var shortcutHintEmphasis: Double {
        usesInvertedActiveForeground ? 1.0 : 0.9
    }

    private var pullRequestForegroundColor: Color {
        isActive ? activeSecondaryColor(0.75) : .secondary
    }

    private var activeBorderLineWidth: CGFloat {
        switch activeTabIndicatorStyle {
        case .leftRail: return 0
        case .solidFill: return isActive ? 1.5 : 0
        }
    }

    private var activeBorderColor: Color {
        guard isActive else { return .clear }
        switch activeTabIndicatorStyle {
        case .leftRail: return .clear
        case .solidFill: return Color.primary.opacity(0.5)
        }
    }

    private var explicitRailColor: Color? {
        guard let railColor = sidebarWorkspaceRowExplicitRailNSColor(
            activeTabIndicatorStyle: activeTabIndicatorStyle,
            customColorHex: workspaceSnapshot.customColorHex,
            colorScheme: colorScheme
        ) else {
            return nil
        }
        return Color(nsColor: railColor).opacity(0.95)
    }

    private var railColor: Color { explicitRailColor ?? .clear }
    private var showsLeadingRail: Bool { explicitRailColor != nil }

    private var backgroundColor: Color {
        let style = sidebarWorkspaceRowBackgroundStyle(
            activeTabIndicatorStyle: activeTabIndicatorStyle,
            isActive: isActive,
            isMultiSelected: isMultiSelected,
            customColorHex: workspaceSnapshot.customColorHex,
            colorScheme: colorScheme,
            sidebarSelectionColorHex: sidebarSelectionColorHex
        )
        guard let color = style.color else { return .clear }
        return Color(nsColor: color).opacity(style.opacity)
    }

    private func tabColorSwatchColor(for hex: String) -> NSColor {
        WorkspaceTabColorSettings.displayNSColor(
            hex: hex,
            colorScheme: colorScheme,
            forceBright: activeTabIndicatorStyle == .leftRail
        ) ?? NSColor(hex: hex) ?? .gray
    }

    /// The resolved appearance the row renders. The row re-invokes `makeStyle`
    /// with the live `ColorScheme`, so color overrides track scheme changes.
    func makeStyle() -> TabItemRowStyle {
        TabItemRowStyle(
            activeSecondaryColor: { activeSecondaryColor($0) },
            primaryTextColor: activePrimaryTextColor,
            unreadBadgeFillColor: activeUnreadBadgeFillColor,
            unreadBadgeTextColor: activeUnreadBadgeTextColor,
            progressTrackColor: activeProgressTrackColor,
            progressFillColor: activeProgressFillColor,
            pullRequestForegroundColor: pullRequestForegroundColor,
            backgroundColor: backgroundColor,
            borderColor: activeBorderColor,
            borderLineWidth: activeBorderLineWidth,
            showsLeadingRail: showsLeadingRail,
            railColor: railColor,
            usesInvertedActiveForeground: usesInvertedActiveForeground,
            shortcutHintEmphasis: shortcutHintEmphasis,
            titleFontWeight: .semibold,
            fontScale: fontScale,
            accentColor: cmuxAccentColor()
        )
    }

    // MARK: - Workspace snapshot

    private var remoteWorkspaceSidebarText: String? {
        guard tab.isRemoteWorkspace else { return nil }
        let trimmedTarget = tab.remoteDisplayTarget?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedTarget, !trimmedTarget.isEmpty {
            return trimmedTarget
        }
        return String(localized: "sidebar.remote.subtitleFallback", defaultValue: "Remote workspace")
    }

    private var copyableSidebarSSHError: String? {
        let fallbackTarget = tab.remoteDisplayTarget ?? String(
            localized: "sidebar.remote.help.targetFallback",
            defaultValue: "remote host"
        )
        let trimmedDetail = tab.remoteConnectionCoordinator.state.remoteConnectionDetail?.trimmingCharacters(in: .whitespacesAndNewlines)
        if tab.remoteConnectionCoordinator.state.remoteConnectionState == .error || tab.remoteConnectionCoordinator.state.remoteConnectionState == .suspended,
           let trimmedDetail, !trimmedDetail.isEmpty {
            let entry = SidebarRemoteErrorCopyEntry(
                workspaceTitle: tab.title,
                target: fallbackTarget,
                detail: trimmedDetail
            )
            return SidebarRemoteErrorCopySupport.clipboardText(for: [entry])
        }
        if let statusValue = tab.statusEntries["remote.error"]?.value
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !statusValue.isEmpty {
            let entry = SidebarRemoteErrorCopyEntry(
                workspaceTitle: tab.title,
                target: fallbackTarget,
                detail: statusValue
            )
            return SidebarRemoteErrorCopySupport.clipboardText(for: [entry])
        }
        return nil
    }

    private var remoteConnectionStatusText: String {
        switch tab.remoteConnectionCoordinator.state.remoteConnectionState {
        case .connected: return String(localized: "remote.status.connected", defaultValue: "Connected")
        case .connecting: return String(localized: "remote.status.connecting", defaultValue: "Connecting")
        case .reconnecting: return String(localized: "remote.status.reconnecting", defaultValue: "Reconnecting")
        case .error: return String(localized: "remote.status.error", defaultValue: "Error")
        case .disconnected: return String(localized: "remote.status.disconnected", defaultValue: "Disconnected")
        case .suspended: return String(localized: "remote.status.suspended", defaultValue: "Unreachable")
        }
    }

    private var remoteStateHelpText: String {
        let target = tab.remoteDisplayTarget ?? String(
            localized: "sidebar.remote.help.targetFallback",
            defaultValue: "remote host"
        )
        let detail = tab.remoteConnectionCoordinator.state.remoteConnectionDetail?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch tab.remoteConnectionCoordinator.state.remoteConnectionState {
        case .connected:
            return String(format: String(localized: "sidebar.remote.help.connected", defaultValue: "Remote connected to %@"), locale: .current, target)
        case .connecting:
            return String(format: String(localized: "sidebar.remote.help.connecting", defaultValue: "Remote connecting to %@"), locale: .current, target)
        case .reconnecting:
            return String(format: String(localized: "sidebar.remote.help.reconnecting", defaultValue: "Remote reconnecting to %@"), locale: .current, target)
        case .error:
            if let detail, !detail.isEmpty {
                return String(format: String(localized: "sidebar.remote.help.errorWithDetail", defaultValue: "Remote error for %@: %@"), locale: .current, target, detail)
            }
            return String(format: String(localized: "sidebar.remote.help.error", defaultValue: "Remote error for %@"), locale: .current, target)
        case .disconnected:
            return String(format: String(localized: "sidebar.remote.help.disconnected", defaultValue: "Remote disconnected from %@"), locale: .current, target)
        case .suspended:
            return String(format: String(localized: "sidebar.remote.help.suspended", defaultValue: "SSH host %@ is unreachable. Automatic reconnect is paused — use Reconnect to retry."), locale: .current, target)
        }
    }

    private var sidebarVisibleCustomDescription: String? {
        guard let description = tab.customDescription else { return nil }
        if tab.title.hasPrefix("vm:"),
           description.trimmingCharacters(in: .whitespacesAndNewlines) == Self.legacyVMWebSocketDescription {
            return nil
        }
        return description
    }

    private var workspaceSnapshotPresentationKey: SidebarWorkspaceSnapshotBuilder.PresentationKey {
        SidebarWorkspaceSnapshotBuilder.PresentationKey(
            showsWorkspaceDescription: settings.showsWorkspaceDescription,
            usesVerticalBranchLayout: sidebarBranchVerticalLayout,
            showsGitBranch: sidebarShowGitBranch,
            usesViewportAwarePath: sidebarUsesLastSegmentPath,
            visibleAuxiliaryDetails: visibleAuxiliaryDetails
        )
    }

    private var workspaceSnapshot: SidebarWorkspaceSnapshotBuilder.Snapshot {
        makeWorkspaceSnapshot()
    }

    func makeWorkspaceSnapshot() -> SidebarWorkspaceSnapshotBuilder.Snapshot {
        let detailVisibility = visibleAuxiliaryDetails
        let orderedPanelIds: [UUID]? = (detailVisibility.showsBranchDirectory || detailVisibility.showsPullRequests)
            ? tab.sidebarOrderedPanelIds()
            : nil
        let compactGitBranchSummaryText: String? = {
            guard detailVisibility.showsBranchDirectory,
                  !sidebarBranchVerticalLayout,
                  sidebarShowGitBranch,
                  let orderedPanelIds else {
                return nil
            }
            return gitBranchSummaryText(orderedPanelIds: orderedPanelIds)
        }()
        let compactDirectoryCandidates: [String] = {
            guard detailVisibility.showsBranchDirectory,
                  !sidebarBranchVerticalLayout,
                  let orderedPanelIds else {
                return []
            }
            return compactDirectoryCandidatesList(orderedPanelIds: orderedPanelIds)
        }()
        let compactBranchDirectoryCandidates = compactBranchDirectoryCandidatesList(
            gitSummary: compactGitBranchSummaryText,
            directoryCandidates: compactDirectoryCandidates
        )
        let branchDirectoryLines: [SidebarWorkspaceSnapshotBuilder.VerticalBranchDirectoryLine] = {
            guard detailVisibility.showsBranchDirectory,
                  sidebarBranchVerticalLayout,
                  let orderedPanelIds else {
                return []
            }
            return verticalBranchDirectoryLines(orderedPanelIds: orderedPanelIds)
        }()
        let branchLinesContainBranch = sidebarShowGitBranch && branchDirectoryLines.contains { $0.branch != nil }
        let pullRequestRows: [SidebarWorkspaceSnapshotBuilder.PullRequestDisplay] = {
            guard detailVisibility.showsPullRequests, let orderedPanelIds else { return [] }
            return pullRequestDisplays(orderedPanelIds: orderedPanelIds)
        }()

        return SidebarWorkspaceSnapshotBuilder.Snapshot(
            presentationKey: workspaceSnapshotPresentationKey,
            title: tab.title,
            customDescription: settings.showsWorkspaceDescription ? sidebarVisibleCustomDescription : nil,
            isPinned: tab.isPinned,
            customColorHex: tab.customColor,
            remoteWorkspaceSidebarText: remoteWorkspaceSidebarText,
            remoteConnectionStatusText: remoteConnectionStatusText,
            remoteStateHelpText: remoteStateHelpText,
            showsRemoteReconnectAffordance: tab.remoteConnectionCoordinator.state.remoteConnectionState == .suspended
                || tab.remoteConnectionCoordinator.state.remoteConnectionState == .disconnected,
            copyableSidebarSSHError: copyableSidebarSSHError,
            latestConversationMessage: tab.latestConversationMessage,
            metadataEntries: detailVisibility.showsMetadata ? tab.sidebarStatusEntriesInDisplayOrder() : [],
            metadataBlocks: detailVisibility.showsMetadata ? tab.sidebarMetadataBlocksInDisplayOrder() : [],
            latestLog: detailVisibility.showsLog ? tab.logEntries.last : nil,
            progress: detailVisibility.showsProgress ? tab.progress : nil,
            compactGitBranchSummaryText: compactGitBranchSummaryText,
            compactDirectoryCandidates: compactDirectoryCandidates,
            compactBranchDirectoryCandidates: compactBranchDirectoryCandidates,
            branchDirectoryLines: branchDirectoryLines,
            branchLinesContainBranch: branchLinesContainBranch,
            pullRequestRows: pullRequestRows,
            listeningPorts: detailVisibility.showsPorts ? tab.listeningPorts : [],
            finderDirectoryPath: WorkspaceFinderDirectoryResolver.path(for: tab)
        )
    }

    private func compactBranchDirectoryCandidatesList(
        gitSummary: String?,
        directoryCandidates: [String]
    ) -> [String] {
        if directoryCandidates.isEmpty {
            return gitSummary.flatMap { $0.isEmpty ? nil : [$0] } ?? []
        }
        guard let gitSummary, !gitSummary.isEmpty else { return directoryCandidates }
        return directoryCandidates.map { "\(gitSummary) · \($0)" }
    }

    private func gitBranchSummaryText(orderedPanelIds: [UUID]) -> String? {
        let lines = gitBranchSummaryLines(orderedPanelIds: orderedPanelIds)
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: " | ")
    }

    private func gitBranchSummaryLines(orderedPanelIds: [UUID]) -> [String] {
        tab.sidebarGitBranchesInDisplayOrder(orderedPanelIds: orderedPanelIds).map { branch in
            "\(branch.branch)\(branch.isDirty ? "*" : "")"
        }
    }

    private func verticalBranchDirectoryLines(orderedPanelIds: [UUID]) -> [SidebarWorkspaceSnapshotBuilder.VerticalBranchDirectoryLine] {
        let entries = tab.sidebarBranchDirectoryEntriesInDisplayOrder(orderedPanelIds: orderedPanelIds)
        let home = SidebarPathFormatter.homeDirectoryPath
        let useViewportAwarePath = sidebarUsesLastSegmentPath
        return entries.compactMap { entry in
            let branchText: String? = {
                guard sidebarShowGitBranch, let branch = entry.branch else { return nil }
                return "\(branch)\(entry.isDirty ? "*" : "")"
            }()

            let directoryCandidates: [String] = {
                guard let directory = entry.directory else { return [] }
                if useViewportAwarePath {
                    return SidebarPathFormatter.pathCandidates(directory, homeDirectoryPath: home)
                }
                let shortened = SidebarPathFormatter.shortenedPath(directory, homeDirectoryPath: home)
                return shortened.isEmpty ? [] : [shortened]
            }()

            if branchText == nil && directoryCandidates.isEmpty {
                return nil
            }
            return SidebarWorkspaceSnapshotBuilder.VerticalBranchDirectoryLine(
                branch: branchText,
                directoryCandidates: directoryCandidates
            )
        }
    }

    private func compactDirectoryCandidatesList(orderedPanelIds: [UUID]) -> [String] {
        let home = SidebarPathFormatter.homeDirectoryPath
        let directories = tab.sidebarDirectoriesInDisplayOrder(orderedPanelIds: orderedPanelIds)
        guard !directories.isEmpty else { return [] }

        if !sidebarUsesLastSegmentPath {
            let joined = directories
                .map { SidebarPathFormatter.shortenedPath($0, homeDirectoryPath: home) }
                .filter { !$0.isEmpty }
                .joined(separator: " | ")
            return joined.isEmpty ? [] : [joined]
        }

        let perDirectoryCandidates: [[String]] = directories
            .map { SidebarPathFormatter.pathCandidates($0, homeDirectoryPath: home) }
            .filter { !$0.isEmpty }
        guard !perDirectoryCandidates.isEmpty else { return [] }

        var indices = Array(repeating: 0, count: perDirectoryCandidates.count)
        var result: [String] = []
        while true {
            let pieces = zip(indices, perDirectoryCandidates).map { idx, candidates in
                candidates[idx]
            }
            let joined = pieces.joined(separator: " | ")
            if !joined.isEmpty, result.last != joined {
                result.append(joined)
            }
            guard let bumpIdx = indices.indices.last(where: { indices[$0] < perDirectoryCandidates[$0].count - 1 }) else {
                break
            }
            indices[bumpIdx] += 1
        }
        return result
    }

    private func pullRequestDisplays(orderedPanelIds: [UUID]) -> [SidebarWorkspaceSnapshotBuilder.PullRequestDisplay] {
        tab.sidebarPullRequestsInDisplayOrder(orderedPanelIds: orderedPanelIds).map { pullRequest in
            SidebarWorkspaceSnapshotBuilder.PullRequestDisplay(
                id: "\(pullRequest.label.lowercased())#\(pullRequest.number)|\(pullRequest.url.absoluteString)",
                number: pullRequest.number,
                label: pullRequest.label,
                url: pullRequest.url,
                status: pullRequest.status,
                isStale: pullRequest.isStale
            )
        }
    }

    // MARK: - Labels

    func pullRequestStatusLabel(_ status: SidebarPullRequestStatus) -> String {
        switch status {
        case .open: return String(localized: "sidebar.pullRequest.statusOpen", defaultValue: "open")
        case .merged: return String(localized: "sidebar.pullRequest.statusMerged", defaultValue: "merged")
        case .closed: return String(localized: "sidebar.pullRequest.statusClosed", defaultValue: "closed")
        }
    }

    func portLabel(_ port: Int) -> String {
        SidebarPortDisplayText.label(for: port)
    }

    func portTooltip(_ port: Int) -> String {
        SidebarPortDisplayText.openTooltip(for: port)
    }

    // MARK: - Actions

    func updateSelection() {
        let modifiers = NSEvent.modifierFlags
        let isCommand = modifiers.contains(.command)
        let isShift = modifiers.contains(.shift)
        let wasSelected = tabManager.selectedTabId == tab.id
        #if DEBUG
        var modStr = ""
        if modifiers.contains(.command) { modStr += "cmd " }
        if modifiers.contains(.shift) { modStr += "shift " }
        if modifiers.contains(.option) { modStr += "opt " }
        if modifiers.contains(.control) { modStr += "ctrl " }
        cmuxDebugLog("sidebar.select workspace=\(tab.id.uuidString.prefix(5)) modifiers=\(modStr.isEmpty ? "none" : modStr.trimmingCharacters(in: .whitespaces))")
        #endif

        let workspaceIds = tabManager.tabs.map(\.id)
        let shiftAnchorIndex = isShift
            ? SidebarWorkspaceSelectionSyncPolicy().shiftClickAnchorIndex(
                existingAnchorIndex: lastSidebarSelectionIndex.wrappedValue,
                selectedWorkspaceIds: selectedTabIds.wrappedValue,
                focusedWorkspaceId: tabManager.selectedTabId,
                liveWorkspaceIds: workspaceIds
            )
            : nil

        if isShift, let anchorIndex = shiftAnchorIndex {
            let lower = min(anchorIndex, index)
            let upper = max(anchorIndex, index)
            let collapsedGroupIds: Set<UUID> = Set(
                tabManager.workspaceGroups
                    .filter { $0.isCollapsed }
                    .map(\.id)
            )
            let anchorIdsByGroup: [UUID: UUID] = Dictionary(
                uniqueKeysWithValues: tabManager.workspaceGroups.map { ($0.id, $0.anchorWorkspaceId) }
            )
            let rangeIds = tabManager.tabs[lower...upper].compactMap { tab -> UUID? in
                if let gid = tab.groupId,
                   collapsedGroupIds.contains(gid),
                   anchorIdsByGroup[gid] != tab.id {
                    return nil
                }
                return tab.id
            }
            if isCommand {
                selectedTabIds.wrappedValue.formUnion(rangeIds)
            } else {
                selectedTabIds.wrappedValue = Set(rangeIds)
            }
        } else if isCommand {
            if selectedTabIds.wrappedValue.contains(tab.id) {
                selectedTabIds.wrappedValue.remove(tab.id)
            } else {
                selectedTabIds.wrappedValue.insert(tab.id)
            }
        } else {
            selectedTabIds.wrappedValue = [tab.id]
        }

        lastSidebarSelectionIndex.wrappedValue = SidebarWorkspaceSelectionSyncPolicy().anchorIndexAfterWorkspaceClick(
            isShiftClick: isShift,
            resolvedShiftAnchorIndex: shiftAnchorIndex,
            clickedIndex: index
        )
        tabManager.selectTab(tab)
        if wasSelected, !isCommand, !isShift {
            tabManager.dismissNotificationOnDirectInteraction(
                tabId: tab.id,
                surfaceId: tabManager.focusedSurfaceId(for: tab.id)
            )
        }
        setSelectionToTabs()
    }

    func closeWorkspace(method: String) {
        #if DEBUG
        cmuxDebugLog("sidebar.close workspace=\(tab.id.uuidString.prefix(5)) method=\(method)")
        #endif
        tabManager.closeWorkspaceWithConfirmation(tab)
    }

    func reconnect() {
        tab.remoteConnectionCoordinator.reconnectRemoteConnection()
    }

    func moveBy(_ delta: Int) {
        let targetIndex = index + delta
        guard targetIndex >= 0, targetIndex < tabManager.tabs.count else { return }
        guard tabManager.reorderWorkspace(tabId: tab.id, toIndex: targetIndex) else { return }
        selectedTabIds.wrappedValue = [tab.id]
        lastSidebarSelectionIndex.wrappedValue = tabManager.tabs.firstIndex { $0.id == tab.id }
        tabManager.selectTab(tab)
        setSelectionToTabs()
    }

    private func closeTabs(_ targetIds: [UUID], allowPinned: Bool) {
        tabManager.closeWorkspacesWithConfirmation(targetIds, allowPinned: allowPinned)
        syncSelectionAfterMutation()
    }

    private func closeOtherTabs(_ targetIds: [UUID]) {
        let keepIds = Set(targetIds)
        let idsToClose = tabManager.tabs.compactMap { keepIds.contains($0.id) ? nil : $0.id }
        closeTabs(idsToClose, allowPinned: true)
    }

    private func closeTabsBelow(tabId: UUID) {
        guard let anchorIndex = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let idsToClose = tabManager.tabs.suffix(from: anchorIndex + 1).map { $0.id }
        closeTabs(idsToClose, allowPinned: true)
    }

    private func closeTabsAbove(tabId: UUID) {
        guard let anchorIndex = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let idsToClose = tabManager.tabs.prefix(upTo: anchorIndex).map { $0.id }
        closeTabs(idsToClose, allowPinned: true)
    }

    private func markTabsRead(_ targetIds: [UUID]) {
        for id in targetIds { notificationStore.markRead(forTabId: id) }
    }

    private func markTabsUnread(_ targetIds: [UUID]) {
        for id in targetIds { notificationStore.markUnread(forTabId: id) }
    }

    private func clearLatestNotifications(_ targetIds: [UUID]) {
        for id in targetIds { notificationStore.clearLatestNotification(forTabId: id) }
    }

    private func hasLatestNotifications(in targetIds: [UUID]) -> Bool {
        targetIds.contains { notificationStore.latestNotification(forTabId: $0) != nil }
    }

    private func syncSelectionAfterMutation() {
        let existingIds = Set(tabManager.tabs.map { $0.id })
        selectedTabIds.wrappedValue = selectedTabIds.wrappedValue.filter { existingIds.contains($0) }
        if selectedTabIds.wrappedValue.isEmpty, let selectedId = tabManager.selectedTabId {
            selectedTabIds.wrappedValue = [selectedId]
        }
        if let selectedId = tabManager.selectedTabId {
            lastSidebarSelectionIndex.wrappedValue = tabManager.tabs.firstIndex { $0.id == selectedId }
        }
    }

    private func moveWorkspaces(_ workspaceIds: [UUID], toWindow windowId: UUID) {
        guard let app = AppDelegate.shared else { return }
        let orderedWorkspaceIds = tabManager.tabs.compactMap { workspaceIds.contains($0.id) ? $0.id : nil }
        guard !orderedWorkspaceIds.isEmpty else { return }
        for (index, workspaceId) in orderedWorkspaceIds.enumerated() {
            let shouldFocus = index == orderedWorkspaceIds.count - 1
            _ = app.moveWorkspaceToWindow(workspaceId: workspaceId, windowId: windowId, focus: shouldFocus)
        }
        selectedTabIds.wrappedValue.subtract(orderedWorkspaceIds)
        syncSelectionAfterMutation()
    }

    private func moveWorkspacesToNewWindow(_ workspaceIds: [UUID]) {
        guard let app = AppDelegate.shared else { return }
        let orderedWorkspaceIds = tabManager.tabs.compactMap { workspaceIds.contains($0.id) ? $0.id : nil }
        guard let firstWorkspaceId = orderedWorkspaceIds.first else { return }
        let shouldFocusImmediately = orderedWorkspaceIds.count == 1
        guard let newWindowId = app.moveWorkspaceToNewWindow(workspaceId: firstWorkspaceId, focus: shouldFocusImmediately) else {
            return
        }
        if orderedWorkspaceIds.count > 1 {
            for workspaceId in orderedWorkspaceIds.dropFirst() {
                _ = app.moveWorkspaceToWindow(workspaceId: workspaceId, windowId: newWindowId, focus: false)
            }
            if let finalWorkspaceId = orderedWorkspaceIds.last {
                _ = app.moveWorkspaceToWindow(workspaceId: finalWorkspaceId, windowId: newWindowId, focus: true)
            }
        }
        selectedTabIds.wrappedValue.subtract(orderedWorkspaceIds)
        syncSelectionAfterMutation()
    }

    private func applyTabColor(_ hex: String?, targetIds: [UUID]) {
        tabManager.applyWorkspaceColor(hex, toWorkspaceIds: targetIds)
    }

    private func promptCustomColor(targetIds: [UUID]) {
        let alert = NSAlert()
        alert.messageText = String(localized: "alert.customColor.title", defaultValue: "Custom Workspace Color")
        alert.informativeText = String(localized: "alert.customColor.message", defaultValue: "Enter a hex color in the format #RRGGBB.")

        let seed = tab.customColor ?? WorkspaceTabColorSettings.customPaletteEntries().first?.hex ?? ""
        let input = NSTextField(string: seed)
        input.placeholderString = "#1565C0"
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "alert.customColor.apply", defaultValue: "Apply"))
        alert.addButton(withTitle: String(localized: "alert.customColor.cancel", defaultValue: "Cancel"))

        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        DispatchQueue.main.async {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        guard let normalized = WorkspaceTabColorSettings.addCustomColor(input.stringValue) else {
            showInvalidColorAlert(input.stringValue)
            return
        }
        applyTabColor(normalized, targetIds: targetIds)
    }

    private func showInvalidColorAlert(_ value: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "alert.invalidColor.title", defaultValue: "Invalid Color")
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            alert.informativeText = String(localized: "alert.invalidColor.emptyMessage", defaultValue: "Enter a hex color in the format #RRGGBB.")
        } else {
            alert.informativeText = String(localized: "alert.invalidColor.invalidMessage", defaultValue: "\"\(trimmed)\" is not a valid hex color. Use #RRGGBB.")
        }
        alert.addButton(withTitle: String(localized: "alert.invalidColor.ok", defaultValue: "OK"))
        _ = alert.runModal()
    }

    private func promptRename() {
        let alert = NSAlert()
        alert.messageText = String(localized: "alert.renameWorkspace.title", defaultValue: "Rename Workspace")
        alert.informativeText = String(localized: "alert.renameWorkspace.message", defaultValue: "Enter a custom name for this workspace.")
        let input = NSTextField(string: tab.customTitle ?? tab.title)
        input.placeholderString = String(localized: "alert.renameWorkspace.placeholder", defaultValue: "Workspace name")
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "alert.renameWorkspace.rename", defaultValue: "Rename"))
        alert.addButton(withTitle: String(localized: "alert.renameWorkspace.cancel", defaultValue: "Cancel"))
        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        DispatchQueue.main.async {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        tabManager.setCustomTitle(tabId: tab.id, title: input.stringValue)
    }

    private func beginWorkspaceDescriptionEditFromContextMenu() {
        selectedTabIds.wrappedValue = [tab.id]
        lastSidebarSelectionIndex.wrappedValue = index
        tabManager.selectTab(tab)
        setSelectionToTabs()
        _ = AppDelegate.shared?.requestEditWorkspaceDescriptionViaCommandPalette()
    }

    private func openPullRequestLink(_ url: URL) {
        updateSelection()
        if openSidebarPullRequestLinksInCmuxBrowser {
            if tabManager.openBrowser(inWorkspace: tab.id, url: url, preferSplitRight: true, insertAtEnd: true) == nil {
                NSWorkspace.shared.open(url)
            }
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func openPortLink(_ port: Int) {
        guard let url = URL(string: "http://localhost:\(port)") else { return }
        updateSelection()
        if openSidebarPortLinksInCmuxBrowser {
            if tabManager.openBrowser(inWorkspace: tab.id, url: url, preferSplitRight: true, insertAtEnd: true) == nil {
                NSWorkspace.shared.open(url)
            }
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openPullRequest(_ url: URL) { openPullRequestLink(url) }
    func openPort(_ port: Int) { openPortLink(port) }

    private func copyWorkspaceIdsToPasteboard(_ ids: [UUID], includeRefs: Bool = false) {
        WorkspaceSurfaceIdentifierClipboardText.copyWorkspaceIds(ids, includeRefs: includeRefs)
    }

    private func copyWorkspaceLinksToPasteboard(_ ids: [UUID]) {
        WorkspaceSurfaceIdentifierClipboardText.copyWorkspaceLinks(ids)
    }

    private func remoteContextMenuWorkspaces() -> [Workspace] {
        guard !remoteContextMenuWorkspaceIds.isEmpty else { return [] }
        return remoteContextMenuWorkspaceIds.compactMap { workspaceId in
            tabManager.tabs.first(where: { $0.id == workspaceId })
        }
    }

    private func contextMenuLabel(multi: String, single: String, isMulti: Bool) -> String {
        isMulti ? multi : single
    }

    // MARK: - Context menu data + actions

    func contextMenuData(snapshot: SidebarWorkspaceSnapshotBuilder.Snapshot) -> SidebarWorkspaceContextMenuData {
        let targetIds = contextMenuWorkspaceIds
        let isMulti = targetIds.count > 1
        let shouldPin = contextMenuPinState?.pinned ?? !tab.isPinned
        let reconnectLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.reconnectWorkspaces", defaultValue: "Reconnect Workspaces"),
            single: String(localized: "contextMenu.reconnectWorkspace", defaultValue: "Reconnect Workspace"),
            isMulti: isMulti)
        let disconnectLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.disconnectWorkspaces", defaultValue: "Disconnect Workspaces"),
            single: String(localized: "contextMenu.disconnectWorkspace", defaultValue: "Disconnect Workspace"),
            isMulti: isMulti)
        let pinLabel = shouldPin
            ? contextMenuLabel(
                multi: String(localized: "contextMenu.pinWorkspaces", defaultValue: "Pin Workspaces"),
                single: String(localized: "contextMenu.pinWorkspace", defaultValue: "Pin Workspace"),
                isMulti: isMulti)
            : contextMenuLabel(
                multi: String(localized: "contextMenu.unpinWorkspaces", defaultValue: "Unpin Workspaces"),
                single: String(localized: "contextMenu.unpinWorkspace", defaultValue: "Unpin Workspace"),
                isMulti: isMulti)
        let closeLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.closeWorkspaces", defaultValue: "Close Workspaces"),
            single: String(localized: "contextMenu.closeWorkspace", defaultValue: "Close Workspace"),
            isMulti: isMulti)
        let markReadLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.markWorkspacesRead", defaultValue: "Mark Workspaces as Read"),
            single: String(localized: "contextMenu.markWorkspaceRead", defaultValue: "Mark Workspace as Read"),
            isMulti: isMulti)
        let markUnreadLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.markWorkspacesUnread", defaultValue: "Mark Workspaces as Unread"),
            single: String(localized: "contextMenu.markWorkspaceUnread", defaultValue: "Mark Workspace as Unread"),
            isMulti: isMulti)
        let clearLatestNotificationLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.clearLatestNotifications", defaultValue: "Clear Latest Notifications"),
            single: String(localized: "contextMenu.clearLatestNotification", defaultValue: "Clear Latest Notification"),
            isMulti: isMulti)
        let copyWorkspaceIDLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.copyWorkspaceIDs", defaultValue: "Copy Workspace IDs"),
            single: String(localized: "contextMenu.copyWorkspaceID", defaultValue: "Copy Workspace ID"),
            isMulti: isMulti)
        let copyWorkspaceLinkLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.copyWorkspaceLinks", defaultValue: "Copy Workspace Links"),
            single: String(localized: "contextMenu.copyWorkspaceLink", defaultValue: "Copy Workspace Link"),
            isMulti: isMulti)
        let renameWorkspaceShortcut = KeyboardShortcutSettings.shortcut(for: .renameWorkspace)
        let editWorkspaceDescriptionShortcut = KeyboardShortcutSettings.shortcut(for: .editWorkspaceDescription)
        let closeWorkspaceShortcut = KeyboardShortcutSettings.shortcut(for: .closeWorkspace)
        let groupSelectedShortcut = KeyboardShortcutSettings.shortcut(for: .groupSelectedWorkspaces)
        let groupInputs = workspaceGroupMenuInputs(targetIds: targetIds)
        let palette = WorkspaceTabColorSettings.palette().map { entry in
            SidebarWorkspaceColorMenuItem(id: entry.id, name: entry.name, hex: entry.hex)
        }
        let referenceWindowId = AppDelegate.shared?.windowId(for: tabManager)
        let windowMoveTargets = (AppDelegate.shared?.windowMoveTargets(referenceWindowId: referenceWindowId) ?? [])
            .map { target in
                SidebarWindowMoveMenuItem(
                    windowId: target.windowId,
                    label: target.label,
                    isCurrentWindow: target.isCurrentWindow
                )
            }

        return SidebarWorkspaceContextMenuData(
            targetIds: targetIds,
            isMulti: isMulti,
            pinLabel: pinLabel,
            pinEnabled: contextMenuPinState != nil,
            groups: groupInputs.groups,
            eligibleGroupTargetIds: groupInputs.eligibleTargetIds,
            allTargetsInSameGroupId: groupInputs.allTargetsInSameGroupId,
            hasAnyGroupedTarget: groupInputs.hasAnyGroupedTarget,
            groupSelectedShortcutKey: groupSelectedShortcut.keyEquivalent,
            groupSelectedShortcutModifiers: groupSelectedShortcut.eventModifiers,
            renameShortcutKey: renameWorkspaceShortcut.keyEquivalent,
            renameShortcutModifiers: renameWorkspaceShortcut.eventModifiers,
            hasCustomTitle: tab.hasCustomTitle,
            editDescriptionShortcutKey: editWorkspaceDescriptionShortcut.keyEquivalent,
            editDescriptionShortcutModifiers: editWorkspaceDescriptionShortcut.eventModifiers,
            hasCustomDescription: tab.hasCustomDescription,
            hasRemoteContextMenuTargets: !remoteContextMenuWorkspaceIds.isEmpty,
            reconnectLabel: reconnectLabel,
            disconnectLabel: disconnectLabel,
            allRemoteTargetsConnecting: allRemoteContextMenuTargetsConnecting,
            allRemoteTargetsDisconnected: allRemoteContextMenuTargetsDisconnected,
            hasCustomColor: tab.customColor != nil,
            colorPalette: palette,
            copyableSidebarSSHError: snapshot.copyableSidebarSSHError,
            isFirstRow: index == 0,
            isLastRow: index >= tabManager.tabs.count - 1,
            windowMoveTargets: windowMoveTargets,
            closeShortcutKey: closeWorkspaceShortcut.keyEquivalent,
            closeShortcutModifiers: closeWorkspaceShortcut.eventModifiers,
            closeLabel: closeLabel,
            closeOthersDisabled: tabManager.tabs.count <= 1 || targetIds.count == tabManager.tabs.count,
            markReadLabel: markReadLabel,
            markUnreadLabel: markUnreadLabel,
            clearLatestNotificationLabel: clearLatestNotificationLabel,
            canMarkRead: notificationStore.canMarkWorkspaceRead(forTabIds: targetIds),
            canMarkUnread: notificationStore.canMarkWorkspaceUnread(forTabIds: targetIds),
            hasLatestNotifications: hasLatestNotifications(in: targetIds),
            copyWorkspaceIDLabel: copyWorkspaceIDLabel,
            copyWorkspaceLinkLabel: copyWorkspaceLinkLabel,
            canShowInFinder: snapshot.finderDirectoryPath != nil
        )
    }

    func contextMenuActions(
        snapshot: SidebarWorkspaceSnapshotBuilder.Snapshot,
        requestShowInFinder: @escaping (TabItemFinderDirectoryOpenRequest) -> Void,
        refreshSnapshot: @escaping () -> Void
    ) -> SidebarWorkspaceContextMenuActions {
        SidebarWorkspaceContextMenuActions(
            colorSwatchImage: { hex in
                coloredCircleImage(color: tabColorSwatchColor(for: hex))
            },
            onPin: {
                guard let contextMenuPinState else {
                    NSSound.beep()
                    return
                }
                let result = WorkspaceActionDispatcher.performPinAction(contextMenuPinState, in: tabManager)
                if result.changedWorkspaceIds.isEmpty {
                    refreshSnapshot()
                }
                syncSelectionAfterMutation()
            },
            onNewGroup: { ids in promptNewWorkspaceGroup(workspaceIds: ids) },
            onMoveToGroup: { ids, groupId in
                for id in ids { tabManager.addWorkspaceToGroup(workspaceId: id, groupId: groupId) }
            },
            onRemoveFromGroup: { ids in
                for id in ids { tabManager.removeWorkspaceFromGroup(workspaceId: id) }
            },
            onRename: { promptRename() },
            onRemoveCustomName: { tabManager.clearCustomTitle(tabId: tab.id) },
            onEditDescription: { beginWorkspaceDescriptionEditFromContextMenu() },
            onClearDescription: { tabManager.clearCustomDescription(tabId: tab.id) },
            onReconnect: {
                for workspace in remoteContextMenuWorkspaces() {
                    workspace.remoteConnectionCoordinator.reconnectRemoteConnection()
                }
            },
            onDisconnect: {
                for workspace in remoteContextMenuWorkspaces() {
                    workspace.remoteConnectionCoordinator.disconnectRemoteConnection(clearConfiguration: false)
                }
            },
            onApplyColor: { hex, ids in applyTabColor(hex, targetIds: ids) },
            onChooseCustomColor: { ids in promptCustomColor(targetIds: ids) },
            onCopySshError: { error in WorkspaceSurfaceIdentifierClipboardText.copy(error) },
            onMoveUp: { moveBy(-1) },
            onMoveDown: { moveBy(1) },
            onMoveToTop: { ids in
                tabManager.moveTabsToTop(Set(ids))
                syncSelectionAfterMutation()
            },
            onMoveToNewWindow: { ids in moveWorkspacesToNewWindow(ids) },
            onMoveToWindow: { ids, windowId in moveWorkspaces(ids, toWindow: windowId) },
            onClose: { ids in closeTabs(ids, allowPinned: true) },
            onCloseOthers: { ids in closeOtherTabs(ids) },
            onCloseBelow: { closeTabsBelow(tabId: tab.id) },
            onCloseAbove: { closeTabsAbove(tabId: tab.id) },
            onMarkRead: { ids in markTabsRead(ids) },
            onMarkUnread: { ids in markTabsUnread(ids) },
            onClearLatestNotifications: { ids in clearLatestNotifications(ids) },
            onCopyWorkspaceIds: { ids in copyWorkspaceIdsToPasteboard(ids) },
            onCopyWorkspaceLinks: { ids in copyWorkspaceLinksToPasteboard(ids) },
            onShowInFinder: {
                let url = snapshot.finderDirectoryPath
                    .map { URL(fileURLWithPath: $0, isDirectory: true) }
                requestShowInFinder(TabItemFinderDirectoryOpenRequest(directoryURL: url))
            }
        )
    }

    // MARK: - Group menu inputs (lifted from TabItemView+WorkspaceGroups)

    private struct WorkspaceGroupMenuInputs {
        let groups: [SidebarWorkspaceGroupMenuItem]
        let eligibleTargetIds: [UUID]
        let allTargetsInSameGroupId: UUID?
        let hasAnyGroupedTarget: Bool
    }

    private func workspaceGroupMenuInputs(targetIds: [UUID]) -> WorkspaceGroupMenuInputs {
        let targetWorkspaces = targetIds.compactMap { id in
            tabManager.tabs.first(where: { $0.id == id })
        }
        let existingAnchorIds = Set(tabManager.workspaceGroups.map(\.anchorWorkspaceId))
        let eligibleTargets = targetWorkspaces.filter { !existingAnchorIds.contains($0.id) }
        let eligibleTargetIds = eligibleTargets.map(\.id)

        let allTargetsInSameGroup: UUID? = {
            let groupIds = eligibleTargets.map(\.groupId)
            guard let first = groupIds.first, groupIds.allSatisfy({ $0 == first }) else {
                return nil
            }
            return first
        }()
        let hasAnyGroupedTarget = eligibleTargets.contains { $0.groupId != nil }

        let groups = workspaceGroupMenuSnapshot.items.map { item in
            SidebarWorkspaceGroupMenuItem(id: item.id, name: item.name)
        }

        return WorkspaceGroupMenuInputs(
            groups: groups,
            eligibleTargetIds: eligibleTargetIds,
            allTargetsInSameGroupId: allTargetsInSameGroup,
            hasAnyGroupedTarget: hasAnyGroupedTarget
        )
    }

    private func promptNewWorkspaceGroup(workspaceIds: [UUID]) {
        guard !workspaceIds.isEmpty else { return }
        tabManager.createWorkspaceGroup(name: "", childWorkspaceIds: workspaceIds)
    }

    var packageContextMenuPinState: TabItemContextMenuPinState? {
        guard let contextMenuPinState else { return nil }
        return TabItemContextMenuPinState(
            targetWorkspaceIds: contextMenuPinState.targetWorkspaceIds,
            anchorWorkspaceId: contextMenuPinState.anchorWorkspaceId,
            pinned: contextMenuPinState.pinned
        )
    }
}
