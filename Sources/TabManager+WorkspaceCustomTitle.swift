import Foundation

extension TabManager {
    /// Sets, replaces, or clears a workspace custom title. Returns whether the
    /// write landed (`.auto` writes are rejected over user-set titles; see
    /// ``Workspace/setCustomTitle(_:source:)``).
    @discardableResult
    func setCustomTitle(
        tabId: UUID,
        title: String?,
        source: Workspace.CustomTitleSource = .user,
        propagateToRemoteTmux: Bool = true
    ) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return false }
        let previousDisplayTitle = resolvedWorkspaceDisplayTitle(for: tabs[index])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let applied = tabs[index].setCustomTitle(title, source: source)
        if applied, selectedTabId == tabId {
            updateWindowTitle(for: tabs[index])
        }
        let currentDisplayTitle = resolvedWorkspaceDisplayTitle(for: tabs[index])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if applied, currentDisplayTitle != previousDisplayTitle {
            NotificationCenter.default.post(
                name: .workspaceTitleDidChange,
                object: self,
                userInfo: [GhosttyNotificationKey.tabId: tabId]
            )
        }
        // A remote tmux mirror workspace rename propagates to `rename-session`,
        // but only when the write landed (an `.auto` write rejected over a
        // user-set title must not desync the remote session name).
        if applied, propagateToRemoteTmux, tabs[index].isRemoteTmuxMirror {
            AppDelegate.shared?.remoteTmuxController.handleMirrorWorkspaceRenamed(
                workspaceId: tabId,
                title: title
            )
        }
        return applied
    }

    func clearCustomTitle(tabId: UUID) {
        setCustomTitle(tabId: tabId, title: nil)
    }

    /// Whether a `.workspaceTitleDidChange` notification should refresh cached
    /// title chrome (content-header text / toolbar command label). Surface-sourced
    /// posts follow the coalescing split; direct workspace-title changes always
    /// refresh for the selected workspace (#7365).
    func shouldRefreshTitleChrome(for notification: Notification) -> Bool {
        shouldRefreshTitleChrome(
            tabId: notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
            surfaceSourced: notification.userInfo?[GhosttyNotificationKey.surfaceId] != nil
        )
    }

    /// Sendable-values core of ``shouldRefreshTitleChrome(for:)`` for observers
    /// that hop actors before deciding: extract `tabId`/`surfaceSourced` where the
    /// notification is delivered, so the non-Sendable `Notification` never crosses
    /// a `Task` boundary.
    func shouldRefreshTitleChrome(tabId: UUID?, surfaceSourced: Bool) -> Bool {
        guard let tabId, tabId == selectedTabId else { return false }
        return !(surfaceSourced && shouldScheduleRawTitleRefresh(forWorkspaceId: tabId))
    }
}
