import AppKit
import SwiftUI
import Foundation
import Bonsplit
import CmuxFileWatch
import CmuxGit
import CmuxProcess
import CoreVideo
import Combine
import CoreServices
import Darwin
import OSLog


// MARK: - Workspace Closing & Confirmation
extension TabManager {
    func closeWorkspace(_ workspace: Workspace, recordHistory: Bool = true) {
        guard tabs.count > 1 else { return }
        sentryBreadcrumb("workspace.close", data: ["tabCount": tabs.count - 1])
        if recordHistory,
           workspace.isRestorableInSessionSnapshot,
           let index = tabs.firstIndex(where: { $0.id == workspace.id }) {
            // Prefer the warm cached agent index over a synchronous
            // RestorableAgentSessionIndex.load() (sysctl-per-record + disk) so closing a
            // workspace does not freeze the main thread; fall back to a fresh load only
            // while the cache has not loaded yet. See closedPanelHistoryEntry.
            let snapshot = workspace.sessionSnapshot(
                includeScrollback: true,
                restorableAgentIndex: SharedLiveAgentIndex.shared.currentIndexSchedulingRefresh()
                    ?? RestorableAgentSessionIndex.load()
            )
            ClosedItemHistoryStore.shared.push(.workspace(ClosedWorkspaceHistoryEntry(
                workspaceId: workspace.id,
                windowId: AppDelegate.shared?.windowId(for: self),
                workspaceIndex: index,
                snapshot: snapshot
            )))
        }
        clearWorkspaceGitProbes(workspaceId: workspace.id)
        clearWorkspacePullRequestTracking(workspaceId: workspace.id)
        sidebarSelectedWorkspaceIds.remove(workspace.id)
        invalidateFocusHistoryTarget(workspaceId: workspace.id, panelId: nil)

        AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: workspace.id)
        workspace.withClosedPanelHistorySuppressed {
            workspace.teardownAllPanels()
        }
        workspace.teardownRemoteConnection()
        unwireClosedBrowserTracking(for: workspace)
        recentlyClosedBrowsers.removeSnapshots(forWorkspaceId: workspace.id)
        workspace.owningTabManager = nil

        if let index = tabs.firstIndex(where: { $0.id == workspace.id }) {
            tabs.remove(at: index)
            // Real-close path: if the closed workspace anchored a group, the
            // group dissolves now and its remaining members survive as
            // ungrouped workspaces. This lives at the explicit close site (not
            // in the tabs didSet) so transient remove/insert reorders never
            // trigger dissolve.
            dissolveGroupsAnchoredBy(closedWorkspaceId: workspace.id)

            if selectedTabId == workspace.id {
                // Keep the "focused index" stable when possible:
                // - If we closed workspace i and there is still a workspace at index i, focus it (the one that moved up).
                // - Otherwise (we closed the last workspace), focus the new last workspace (i-1).
                let newIndex = min(index, max(0, tabs.count - 1))
                selectedTabId = tabs[newIndex].id
            }
        }
        publishCmuxWorkspaceClosed(workspace)
    }

    /// If `closedWorkspaceId` was the anchor of any group, dissolve that group:
    /// remaining members lose their `groupId` and stay in `tabs` as ungrouped
    /// workspaces. Caller is responsible for having already removed the closed
    /// workspace from `tabs`.
    private func dissolveGroupsAnchoredBy(closedWorkspaceId: UUID) {
        let dissolvedGroupIds = workspaceGroups
            .filter { $0.anchorWorkspaceId == closedWorkspaceId }
            .map(\.id)
        guard !dissolvedGroupIds.isEmpty else { return }
        for gid in dissolvedGroupIds {
            for tab in tabs where tab.groupId == gid {
                tab.groupId = nil
            }
        }
        workspaceGroups.removeAll { dissolvedGroupIds.contains($0.id) }
        // Newly-ungrouped members may be sitting above other groups, which
        // violates the renderer's pinned-solo / pinned-groups / unpinned-
        // groups / ungrouped-unpinned ordering invariant. Renormalize so
        // they slide into the ungrouped tier at the bottom.
        normalizeWorkspaceGroupContiguity()
    }

    /// Detach a workspace from this window without closing its panels.
    /// Used by the socket API for cross-window moves.
    @discardableResult
    func detachWorkspace(tabId: UUID) -> Workspace? {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return nil }
        clearWorkspaceGitProbes(workspaceId: tabId)
        sidebarSelectedWorkspaceIds.remove(tabId)
        invalidateFocusHistoryTarget(workspaceId: tabId, panelId: nil)

        let removed = tabs.remove(at: index)
        // Same anchor-close lifecycle as closeWorkspace: detaching a group's
        // anchor dissolves the group; non-anchor members stay in tabs as
        // ungrouped workspaces.
        dissolveGroupsAnchoredBy(closedWorkspaceId: removed.id)
        // Clear the detached workspace's own group membership so the
        // destination window — which has no matching WorkspaceGroup — doesn't
        // render it as an orphaned indented row with stale grouping state.
        removed.groupId = nil
        unwireClosedBrowserTracking(for: removed)
        recentlyClosedBrowsers.removeSnapshots(forWorkspaceId: removed.id)
        removed.owningTabManager = nil
        lastFocusedPanelByTab.removeValue(forKey: removed.id)

        if tabs.isEmpty {
            // The UI assumes each window always has at least one workspace.
            _ = addWorkspace()
            return removed
        }

        if selectedTabId == removed.id {
            let nextIndex = min(index, max(0, tabs.count - 1))
            selectedTabId = tabs[nextIndex].id
        }

        return removed
    }

    /// Attach an existing workspace to this window.
    func attachWorkspace(_ workspace: Workspace, at index: Int? = nil, select: Bool = true) {
        workspace.owningTabManager = self
        wireClosedBrowserTracking(for: workspace)
        let insertIndex: Int = {
            guard let index else { return tabs.count }
            return max(0, min(index, tabs.count))
        }()
        tabs.insert(workspace, at: insertIndex)
        // A workspace moved in from another window arrives ungrouped (detach
        // clears `groupId`) and may be pinned, so an arbitrary insert index can
        // split a destination group's contiguous run or drop a pinned workspace
        // below unpinned ones. Re-run the same normalization every insertion
        // path uses so the destination's sidebar invariants — leading pinned
        // segment, contiguous group runs — hold regardless of the drop index.
        normalizeWorkspaceGroupContiguity()
        if select {
            selectedTabId = workspace.id
        }
    }

    // Keep closeTab as convenience alias
    func closeTab(_ tab: Workspace) { closeWorkspace(tab) }
    func closeCurrentTabWithConfirmation() { closeCurrentWorkspaceWithConfirmation() }

    func closeCurrentPanelWithConfirmation() {
#if DEBUG
        UITestRecorder.incrementInt("closePanelInvocations")
#endif
        guard !closeConfirmationInFlight else { return }
        guard let selectedId = selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedId }) else { return }
        reconcileFocusedPanelFromFirstResponderForKeyboard()
        guard let focusedPanelId = shortcutCloseTargetPanelId(in: tab) else { return }
        closePanelWithConfirmation(tab: tab, panelId: focusedPanelId)
    }

    func canCloseOtherTabsInFocusedPane() -> Bool {
        closeOtherTabsInFocusedPanePlan() != nil
    }

    func closeOtherTabsInFocusedPaneWithConfirmation() {
        guard !closeConfirmationInFlight else { return }
        guard let plan = closeOtherTabsInFocusedPanePlan() else { return }

        if CloseTabConfirmationPolicy.shouldConfirm(requiresConfirmation: true, source: .shortcut) {
            let prompt = CloseOtherTabsConfirmationPrompt(titles: plan.titles)
            guard confirmClose(
                title: prompt.title,
                message: prompt.message,
                acceptCmdD: false
            ) else { return }
        }

        for panelId in plan.panelIds {
            plan.workspace.markCloseHistoryEligible(panelId: panelId)
            _ = plan.workspace.closePanel(panelId, force: true)
        }
    }

    func closeCurrentWorkspaceWithConfirmation() {
#if DEBUG
        UITestRecorder.incrementInt("closeTabInvocations")
#endif
        guard !closeConfirmationInFlight else { return }
        let sidebarSelectionIds = orderedSidebarSelectedWorkspaceIds()
        if sidebarSelectionIds.count > 1 {
            closeWorkspacesWithConfirmation(sidebarSelectionIds, allowPinned: true)
            return
        }
        guard let selectedId = selectedTabId,
              let workspace = tabs.first(where: { $0.id == selectedId }) else { return }
        closeWorkspaceWithConfirmation(workspace)
    }

    func canCloseWorkspace(_ workspace: Workspace, allowPinned: Bool = false) -> Bool {
        allowPinned || !workspace.isPinned
    }

    @discardableResult
    func closeWorkspaceWithConfirmation(_ workspace: Workspace) -> Bool {
        if workspace.isPinned {
            guard confirmPinnedWorkspaceClose(source: .workspace) else { return false }
            closeWorkspaceIfRunningProcess(workspace, requiresConfirmation: false)
            return true
        }
        closeWorkspaceIfRunningProcess(workspace)
        return true
    }

    @discardableResult
    func closeWorkspaceFromCloseTabGesture(_ workspace: Workspace) -> Bool {
        if workspace.isPinned {
            guard confirmPinnedWorkspaceClose(source: .tabClose) else { return false }
            closeWorkspaceIfRunningProcess(workspace, requiresConfirmation: false)
            return true
        }
        closeWorkspaceIfRunningProcess(workspace, source: .tabClose)
        return true
    }

    @discardableResult
    func closeWorkspaceFromTabCloseButton(_ workspace: Workspace) -> Bool {
        if workspace.isPinned {
            guard confirmPinnedWorkspaceClose(source: .tabCloseButton) else { return false }
            closeWorkspaceIfRunningProcess(workspace, requiresConfirmation: false)
            return true
        }
        closeWorkspaceIfRunningProcess(workspace, source: .tabCloseButton)
        return true
    }

    @discardableResult
    func closeWorkspaceWithConfirmation(tabId: UUID) -> Bool {
        guard let workspace = tabs.first(where: { $0.id == tabId }) else { return false }
        return closeWorkspaceWithConfirmation(workspace)
    }

    func setSidebarSelectedWorkspaceIds(_ workspaceIds: Set<UUID>) {
        let existingIds = Set(tabs.map(\.id))
        sidebarSelectedWorkspaceIds = workspaceIds.intersection(existingIds)
    }

    func closeWorkspacesWithConfirmation(_ workspaceIds: [UUID], allowPinned: Bool) {
        let workspaces = orderedClosableWorkspaces(workspaceIds, allowPinned: allowPinned)
        guard !workspaces.isEmpty else { return }
        guard workspaces.count > 1 else {
            closeWorkspaceFromCloseTabGesture(workspaces[0])
            return
        }

        let plan = closeWorkspacesPlan(for: workspaces)
        if shouldConfirmClose(requiresConfirmation: true, source: .tabClose) {
            guard confirmClose(
                title: plan.title,
                message: plan.message,
                acceptCmdD: plan.acceptCmdD
            ) else { return }
        }

        if plan.workspaces.count == tabs.count,
           let firstWorkspace = plan.workspaces.first {
            if let window {
                window.performClose(nil)
                return
            }
            if AppDelegate.shared != nil {
                AppDelegate.shared?.closeMainWindowContainingTabId(firstWorkspace.id)
                return
            }
        }

        for workspace in plan.workspaces {
            guard tabs.contains(where: { $0.id == workspace.id }) else { continue }
            // Anchor-close confirms inside closeWorkspaceIfRunningProcess.
            // If the user cancels that dialog during a batch, abort the
            // whole batch — otherwise the loop keeps closing later items
            // even though the user said "no" to the dialog that was up.
            if let groupId = workspace.groupId,
               let group = workspaceGroups.first(where: { $0.id == groupId }),
               group.anchorWorkspaceId == workspace.id,
               !WorkspaceGroupAnchorCloseSettings.suppressed() {
                let otherMemberCount = tabs.reduce(0) { partial, tab in
                    tab.groupId == groupId && tab.id != workspace.id ? partial + 1 : partial
                }
                if !confirmAnchorWorkspaceClose(groupName: group.name, otherMemberCount: otherMemberCount) {
                    return
                }
                // Anchor confirmed (or suppressed); skip the inner re-prompt
                // by closing without going through closeWorkspaceIfRunningProcess.
                if tabs.count <= 1 {
                    if let window {
                        window.performClose(nil)
                    } else {
                        AppDelegate.shared?.closeMainWindowContainingTabId(workspace.id)
                    }
                } else {
                    closeWorkspace(workspace)
                }
                continue
            }
            closeWorkspaceIfRunningProcess(workspace, requiresConfirmation: false)
        }
    }

    var isCloseConfirmationInFlight: Bool { closeConfirmationInFlight }

    func beginCloseConfirmationSession() -> Bool {
        guard !closeConfirmationInFlight else { return false }
        closeConfirmationInFlight = true
        return true
    }

    func endCloseConfirmationSession() {
        DispatchQueue.main.async { [weak self] in
            self?.closeConfirmationInFlight = false
        }
    }

    func confirmClose(title: String, message: String, acceptCmdD: Bool) -> Bool {
        guard beginCloseConfirmationSession() else { return false }
        defer { endCloseConfirmationSession() }

        if let confirmCloseHandler {
            return confirmCloseHandler(title, message, acceptCmdD)
        }
        _ = acceptCmdD

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "dialog.closeTab.close", defaultValue: "Close"))
        alert.addButton(withTitle: String(localized: "dialog.closeTab.cancel", defaultValue: "Cancel"))

        if let closeButton = alert.buttons.first {
            closeButton.keyEquivalent = "\r"
            closeButton.keyEquivalentModifierMask = []
            alert.window.defaultButtonCell = closeButton.cell as? NSButtonCell
            alert.window.initialFirstResponder = closeButton
        }
        if let cancelButton = alert.buttons.dropFirst().first {
            cancelButton.keyEquivalent = "\u{1b}"
        }

        #if DEBUG
        UITestRecorder.record([
            "closeConfirmationTitle": title,
            "closeConfirmationMessage": message,
        ])
        #endif

        return runCloseConfirmationAlert(alert) == .alertFirstButtonReturn
    }

    private func runCloseConfirmationAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        // Presentation (activate + sheet-on-main-window, else app-modal) is
        // shared with every other cmux dialog via `runCmuxModalAlert`. This
        // wrapper only adds the close-confirmation-specific UITest telemetry,
        // recorded from the presenter's actual path so the label can never
        // disagree with how the alert was really shown.
        return runCmuxModalAlert(
            alert,
            presentingWindow: closeConfirmationPresentingWindow()
        ) { presentation in
            #if DEBUG
            switch presentation {
            case .sheet(let hostWindow):
                // The sheet attaches after this hook returns, so read the
                // attachment on the next runloop turn (during the modal loop).
                DispatchQueue.main.async {
                    UITestRecorder.record([
                        "closeConfirmationPresentation": "sheet",
                        "closeConfirmationAttachedSheet": hostWindow.attachedSheet == nil ? "0" : "1",
                    ])
                }
            case .appModal(let hostWindowHadAttachedSheet):
                UITestRecorder.record([
                    "closeConfirmationPresentation": "appModal",
                    "closeConfirmationAttachedSheet": hostWindowHadAttachedSheet ? "1" : "0",
                ])
            }
            #endif
        }
    }

    private func closeConfirmationPresentingWindow() -> NSWindow? {
        cmuxMainWindowForModalPresentation(preferring: window)
    }

    private struct CloseOtherTabsInFocusedPanePlan {
        let workspace: Workspace
        let panelIds: [UUID]
        let titles: [String]
    }

    private struct CloseWorkspacesPlan {
        let workspaces: [Workspace]
        let title: String
        let message: String
        let acceptCmdD: Bool
    }

    private enum CloseConfirmationSource {
        case workspace
        case tabClose
        case tabCloseButton
    }

    private func closeOtherTabsInFocusedPanePlan() -> CloseOtherTabsInFocusedPanePlan? {
        guard let workspace = selectedWorkspace else { return nil }
        guard let paneId = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else {
            return nil
        }

        let tabsInPane = workspace.bonsplitController.tabs(inPane: paneId)
        guard !tabsInPane.isEmpty else { return nil }
        guard let selectedTabId = workspace.bonsplitController.selectedTab(inPane: paneId)?.id ?? tabsInPane.first?.id else {
            return nil
        }

        var targetPanelIds: [UUID] = []
        var targetTitles: [String] = []
        for tab in tabsInPane where tab.id != selectedTabId {
            guard let panelId = workspace.panelIdFromSurfaceId(tab.id) else { continue }
            if workspace.isPanelPinned(panelId) {
                continue
            }
            targetPanelIds.append(panelId)
            targetTitles.append(CloseOtherTabsConfirmationPrompt.displayTitle(workspace.panelTitle(panelId: panelId)))
        }

        guard !targetPanelIds.isEmpty else { return nil }
        return CloseOtherTabsInFocusedPanePlan(
            workspace: workspace,
            panelIds: targetPanelIds,
            titles: targetTitles
        )
    }

    private func orderedClosableWorkspaces(_ workspaceIds: [UUID], allowPinned: Bool) -> [Workspace] {
        let targetIds = Set(workspaceIds)
        return tabs.compactMap { workspace in
            guard targetIds.contains(workspace.id) else { return nil }
            guard allowPinned || !workspace.isPinned else { return nil }
            return workspace
        }
    }

    private func orderedSidebarSelectedWorkspaceIds() -> [UUID] {
        tabs.compactMap { workspace in
            sidebarSelectedWorkspaceIds.contains(workspace.id) ? workspace.id : nil
        }
    }

    private func closeWorkspacesPlan(for workspaces: [Workspace]) -> CloseWorkspacesPlan {
        let willCloseWindow = workspaces.count == tabs.count
        let title = willCloseWindow
            ? String(localized: "dialog.closeWindow.title", defaultValue: "Close window?")
            : String(localized: "dialog.closeWorkspaces.title", defaultValue: "Close workspaces?")
        let titleLines = workspaces
            .map { "• \(closeWorkspaceDisplayTitle($0.title))" }
            .joined(separator: "\n")
        let format = willCloseWindow
            ? String(
                localized: "dialog.closeWorkspacesWindow.message",
                defaultValue: "This will close the current window, its %1$lld workspaces, and all of their panels:\n%2$@"
            )
            : String(
                localized: "dialog.closeWorkspaces.message",
                defaultValue: "This will close %1$lld workspaces and all of their panels:\n%2$@"
            )
        let message = String(format: format, locale: .current, Int64(workspaces.count), titleLines)
        return CloseWorkspacesPlan(
            workspaces: workspaces,
            title: title,
            message: message,
            acceptCmdD: willCloseWindow
        )
    }

    private func closeWorkspaceDisplayTitle(_ title: String?) -> String {
        let collapsed = title?
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let collapsed, !collapsed.isEmpty {
            return collapsed
        }
        return String(localized: "workspace.displayName.fallback", defaultValue: "Workspace")
    }

    private func closeWorkspaceIfRunningProcess(
        _ workspace: Workspace,
        requiresConfirmation: Bool = true,
        source: CloseConfirmationSource = .workspace
    ) {
        // Anchor-close ALWAYS prompts (subject to its own
        // WorkspaceGroupAnchorCloseSettings.suppressed flag), regardless of
        // requiresConfirmation. Batch-close paths set requiresConfirmation=false
        // after their own generic prompt, but that generic prompt doesn't
        // mention group dissolution — silently ungrouping members during a
        // multi-close would be surprising. The "Don't ask again" toggle on
        // the anchor dialog is the user's opt-out.
        if let groupId = workspace.groupId,
           let group = workspaceGroups.first(where: { $0.id == groupId }),
           group.anchorWorkspaceId == workspace.id {
            let otherMemberCount = tabs.reduce(0) { partial, tab in
                tab.groupId == groupId && tab.id != workspace.id ? partial + 1 : partial
            }
            if !confirmAnchorWorkspaceClose(groupName: group.name, otherMemberCount: otherMemberCount) {
                return
            }
        }
        let willCloseWindow = tabs.count <= 1
        let needsCloseConfirmation = workspaceNeedsConfirmClose(workspace)
        if requiresConfirmation,
           shouldConfirmClose(requiresConfirmation: needsCloseConfirmation, source: source),
           !confirmClose(
               title: String(localized: "dialog.closeWorkspace.title", defaultValue: "Close workspace?"),
               message: String(localized: "dialog.closeWorkspace.message", defaultValue: "This will close the workspace and all of its panels."),
               acceptCmdD: willCloseWindow
           ) {
            return
        }
        if tabs.count <= 1 {
            // Last workspace in this window: match Close Workspace shortcut behavior.
            if let window {
                window.performClose(nil)
            } else {
                AppDelegate.shared?.closeMainWindowContainingTabId(workspace.id)
            }
        } else {
            closeWorkspace(workspace)
        }
    }

    private func shouldConfirmClose(requiresConfirmation: Bool, source: CloseConfirmationSource) -> Bool {
        switch source {
        case .workspace:
            return requiresConfirmation
        case .tabClose:
            return CloseTabConfirmationPolicy.shouldConfirm(
                requiresConfirmation: requiresConfirmation,
                source: .shortcut
            )
        case .tabCloseButton:
            return CloseTabConfirmationPolicy.shouldConfirm(
                requiresConfirmation: requiresConfirmation,
                source: .tabCloseButton
            )
        }
    }

    /// Confirm before closing a workspace that is its group's anchor. Closing
    /// the anchor dissolves the group (other members survive ungrouped).
    /// "Don't ask again" toggles `WorkspaceGroupAnchorCloseSettings.suppressed`.
    private func confirmAnchorWorkspaceClose(groupName: String, otherMemberCount: Int) -> Bool {
        if WorkspaceGroupAnchorCloseSettings.suppressed() {
            return true
        }
        // Do NOT acquire beginCloseConfirmationSession here. The standard
        // close confirmation path that runs immediately after (confirmClose())
        // gates itself with the same flag, and endCloseConfirmationSession
        // releases the flag asynchronously on the next main-queue turn — so
        // wrapping this dialog with begin/end would leave the flag set when
        // the inner confirmClose runs, causing it to return false and silently
        // refuse the close even after the user accepted both prompts.
        let title = String(
            localized: "dialog.closeAnchor.title",
            defaultValue: "Close this workspace?"
        )
        // Use printf-style format specifiers and String(format:) so the
        // catalog entry can substitute the group name and member count at
        // runtime. Embedding Swift `\(groupName)` interpolation in the
        // catalog `value` would render literal `\(groupName)` on lookup.
        let message: String
        if otherMemberCount == 0 {
            let format = String(
                localized: "dialog.closeAnchor.message.lone",
                defaultValue: "Closing this workspace will remove the group \u{201C}%@\u{201D}."
            )
            message = String.localizedStringWithFormat(format, groupName)
        } else if otherMemberCount == 1 {
            let format = String(
                localized: "dialog.closeAnchor.message.one",
                defaultValue: "Closing this workspace will ungroup \u{201C}%@\u{201D} and release 1 other workspace."
            )
            message = String.localizedStringWithFormat(format, groupName)
        } else {
            let format = String(
                localized: "dialog.closeAnchor.message.many",
                defaultValue: "Closing this workspace will ungroup \u{201C}%1$@\u{201D} and release %2$lld other workspaces."
            )
            message = String.localizedStringWithFormat(format, groupName, otherMemberCount)
        }

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "dialog.closeTab.close", defaultValue: "Close"))
        alert.addButton(withTitle: String(localized: "dialog.closeTab.cancel", defaultValue: "Cancel"))
        let suppressionButton = NSButton(
            checkboxWithTitle: String(
                localized: "dialog.dontAskAgain",
                defaultValue: "Don\u{2019}t ask again"
            ),
            target: nil,
            action: nil
        )
        suppressionButton.state = .off
        alert.accessoryView = suppressionButton
        if let closeButton = alert.buttons.first {
            closeButton.keyEquivalent = "\r"
            closeButton.keyEquivalentModifierMask = []
            alert.window.defaultButtonCell = closeButton.cell as? NSButtonCell
            alert.window.initialFirstResponder = closeButton
        }
        if let cancelButton = alert.buttons.dropFirst().first {
            cancelButton.keyEquivalent = "\u{1b}"
        }

        let response = runCloseConfirmationAlert(alert)
        guard response == .alertFirstButtonReturn else { return false }
        if suppressionButton.state == .on {
            WorkspaceGroupAnchorCloseSettings.setSuppressed(true)
        }
        return true
    }

    private func confirmPinnedWorkspaceClose(source: CloseConfirmationSource) -> Bool {
        guard shouldConfirmClose(requiresConfirmation: true, source: source) else { return true }
        return confirmClose(
            title: String(localized: "dialog.closePinnedWorkspace.title", defaultValue: "Close pinned workspace?"),
            message: String(
                localized: "dialog.closePinnedWorkspace.message",
                defaultValue: "This workspace is pinned. Closing it will close the workspace and all of its panels."
            ),
            acceptCmdD: tabs.count <= 1
        )
    }

    func shouldCloseWorkspaceOnLastSurfaceShortcut(_ workspace: Workspace, panelId: UUID) -> Bool {
        LastSurfaceCloseShortcutSettings.closesWorkspace() &&
            workspace.panels.count <= 1 &&
            workspace.panels[panelId] != nil
    }

}
