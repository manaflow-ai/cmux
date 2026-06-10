import Foundation
import SwiftUI
import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxSocketControl
import Combine
import CryptoKit
import Darwin
import Network
import CoreText


// MARK: - Panel access, configuration, and subscriptions
extension Workspace {
    var focusedSurfaceId: UUID? { focusedPanelId }
    var surfaceDirectories: [UUID: String] {
        get { panelDirectories }
        set { panelDirectories = newValue }
    }

    enum SurfaceKind {
        static let terminal = "terminal"
        static let browser = "browser"
        static let markdown = "markdown"
        static let filePreview = "filePreview"
        static let rightSidebarTool = "rightSidebarTool"
        static let agentSession = "agentSession"
        static let project = "project"
        static let extensionBrowser = "extensionBrowser"
    }

    func panelIdFromSurfaceId(_ surfaceId: TabID) -> UUID? {
        surfaceIdToPanelId[surfaceId]
    }

    func surfaceIdFromPanelId(_ panelId: UUID) -> TabID? {
        surfaceIdToPanelId.first { $0.value == panelId }?.key
    }

    func configureNewTerminalPanel(_ terminalPanel: TerminalPanel) {
        if TerminalTextBoxInputSettings.focusOnNewTerminals() {
            terminalPanel.preferTextBoxInputWhenActivated()
        } else if TerminalTextBoxInputSettings.showOnNewTerminals() {
            terminalPanel.showTextBoxInputWhenAvailable()
        }
        configureTerminalPanel(terminalPanel)
    }

    func configureTerminalPanel(_ terminalPanel: TerminalPanel) {
        terminalPanel.onRequestWorkspacePaneFlash = { [weak self, weak terminalPanel] reason in
            guard let self, let terminalPanel else { return }
            self.triggerWorkspacePaneFlash(panelId: terminalPanel.id, reason: reason)
        }
        terminalPanel.onRequestAgentHibernationResume = { [weak self, weak terminalPanel] focus in
            guard let self, let terminalPanel else { return false }
            return self.resumeAgentHibernation(panelId: terminalPanel.id, focus: focus)
        }
    }

    func configureBrowserPanel(_ browserPanel: BrowserPanel) {
        browserPanel.webViewDidRequestClose = { [weak self, weak browserPanel] in
            guard let self, let browserPanel else { return }
            guard self.panels[browserPanel.id] is BrowserPanel else { return }
#if DEBUG
            cmuxDebugLog(
                "browser.close.requestedByPage ws=\(self.id.uuidString.prefix(5)) " +
                "panel=\(browserPanel.id.uuidString.prefix(5))"
            )
#endif
            _ = self.closePanel(browserPanel.id, force: true)
        }
    }

    private func triggerWorkspacePaneFlash(panelId: UUID, reason: WorkspaceAttentionFlashReason) {
        tmuxWorkspaceFlashPanelId = panelId
        tmuxWorkspaceFlashReason = reason
        tmuxWorkspaceFlashToken &+= 1
    }

    func installBrowserPanelSubscription(_ browserPanel: BrowserPanel) {
        let browserTabState = Publishers.CombineLatest4(
            browserPanel.$pageTitle.removeDuplicates(), browserPanel.$currentURL.removeDuplicates(),
            browserPanel.$isLoading.removeDuplicates(), browserPanel.$faviconPNGData.removeDuplicates(by: { $0 == $1 })
        )
        let subscription = browserTabState
        .combineLatest(browserPanel.$isMuted.removeDuplicates())
        .receive(on: DispatchQueue.main)
        .sink { [weak self, weak browserPanel] output in
            let ((_, _, isLoading, favicon), isMuted) = output
            guard let self = self,
                  let browserPanel = browserPanel,
                  let tabId = self.surfaceIdFromPanelId(browserPanel.id) else { return }
            self.publishBrowserOpenTabSuggestion(for: browserPanel)
            guard let existing = self.bonsplitController.tab(tabId) else { return }
            let nextTitle = browserPanel.displayTitle
            if self.panelTitles[browserPanel.id] != nextTitle {
                self.panelTitles[browserPanel.id] = nextTitle
            }
            let resolvedTitle = self.resolvedPanelTitle(panelId: browserPanel.id, fallback: nextTitle)
            let titleUpdate: String? = existing.title == resolvedTitle ? nil : resolvedTitle
            let faviconUpdate: Data?? = existing.iconImageData == favicon ? nil : .some(favicon)
            let loadingUpdate: Bool? = existing.isLoading == isLoading ? nil : isLoading
            let mutedUpdate: Bool? = existing.isAudioMuted == isMuted ? nil : isMuted
            guard titleUpdate != nil || faviconUpdate != nil || loadingUpdate != nil || mutedUpdate != nil else { return }
            self.bonsplitController.updateTab(
                tabId,
                title: titleUpdate,
                iconImageData: faviconUpdate,
                hasCustomTitle: self.panelCustomTitles[browserPanel.id] != nil,
                isLoading: loadingUpdate,
                isAudioMuted: mutedUpdate
            )
        }
        panelSubscriptions[browserPanel.id] = subscription
        publishBrowserOpenTabSuggestion(for: browserPanel)
        setPreferredBrowserProfileID(browserPanel.profileID)
    }

    func syncBrowserAudioMuteStateForPanel(_ panelId: UUID, browserPanel: BrowserPanel? = nil) {
        guard let browserPanel = browserPanel ?? self.browserPanel(for: panelId),
              let tabId = surfaceIdFromPanelId(panelId),
              let tab = bonsplitController.tab(tabId),
              tab.isAudioMuted != browserPanel.isMuted else { return }
        bonsplitController.updateTab(tabId, isAudioMuted: browserPanel.isMuted)
    }

    func setPreferredBrowserProfileID(_ profileID: UUID?) {
        guard let profileID else {
            preferredBrowserProfileID = nil
            return
        }
        guard BrowserProfileStore.shared.profileDefinition(id: profileID) != nil else { return }
        preferredBrowserProfileID = profileID
    }

    func resolvedNewBrowserProfileID(
        preferredProfileID: UUID? = nil,
        sourcePanelId: UUID? = nil
    ) -> UUID {
        if let preferredProfileID,
           BrowserProfileStore.shared.profileDefinition(id: preferredProfileID) != nil {
            return preferredProfileID
        }
        if let sourcePanelId,
           let sourceBrowserPanel = browserPanel(for: sourcePanelId),
           BrowserProfileStore.shared.profileDefinition(id: sourceBrowserPanel.profileID) != nil {
            return sourceBrowserPanel.profileID
        }
        if let preferredBrowserProfileID,
           BrowserProfileStore.shared.profileDefinition(id: preferredBrowserProfileID) != nil {
            return preferredBrowserProfileID
        }
        return BrowserProfileStore.shared.effectiveLastUsedProfileID
    }

    func installMarkdownPanelSubscription(_ markdownPanel: MarkdownPanel) {
        let subscription = Publishers.CombineLatest(
            markdownPanel.$displayTitle.removeDuplicates(),
            markdownPanel.$isDirty.removeDuplicates()
        )
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak markdownPanel] newTitle, isDirty in
                guard let self,
                      let markdownPanel,
                      let tabId = self.surfaceIdFromPanelId(markdownPanel.id) else { return }
                guard let existing = self.bonsplitController.tab(tabId) else { return }

                if self.panelTitles[markdownPanel.id] != newTitle {
                    self.panelTitles[markdownPanel.id] = newTitle
                }
                let resolvedTitle = self.resolvedPanelTitle(panelId: markdownPanel.id, fallback: newTitle)
                let titleUpdate: String? = existing.title == resolvedTitle ? nil : resolvedTitle
                let dirtyUpdate: Bool? = existing.isDirty == isDirty ? nil : isDirty
                guard titleUpdate != nil || dirtyUpdate != nil else { return }
                self.bonsplitController.updateTab(
                    tabId,
                    title: titleUpdate,
                    hasCustomTitle: self.panelCustomTitles[markdownPanel.id] != nil,
                    isDirty: dirtyUpdate
                )
            }
        panelSubscriptions[markdownPanel.id] = subscription
    }

    func installFilePreviewPanelSubscription(_ filePreviewPanel: FilePreviewPanel) {
        let titleAndDirty = Publishers.CombineLatest(
            filePreviewPanel.$displayTitle.removeDuplicates(),
            filePreviewPanel.$isDirty.removeDuplicates()
        )
        let subscription = Publishers.CombineLatest(
            titleAndDirty,
            filePreviewPanel.$displayIcon.removeDuplicates()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self, weak filePreviewPanel] titleAndDirty, displayIcon in
            guard let self,
                  let filePreviewPanel,
                  let tabId = self.surfaceIdFromPanelId(filePreviewPanel.id) else { return }
            let (newTitle, isDirty) = titleAndDirty
            guard let existing = self.bonsplitController.tab(tabId) else { return }

            if self.panelTitles[filePreviewPanel.id] != newTitle {
                self.panelTitles[filePreviewPanel.id] = newTitle
            }
            let resolvedTitle = self.resolvedPanelTitle(panelId: filePreviewPanel.id, fallback: newTitle)
            let resolvedIcon = RenderableSystemSymbol.resolvedSurfaceTabIcon(displayIcon)
            let titleUpdate: String? = existing.title == resolvedTitle ? nil : resolvedTitle
            let iconUpdate: String?? = existing.icon == resolvedIcon ? nil : .some(resolvedIcon)
            let dirtyUpdate: Bool? = existing.isDirty == isDirty ? nil : isDirty
            guard titleUpdate != nil || iconUpdate != nil || dirtyUpdate != nil else { return }
            self.bonsplitController.updateTab(
                tabId,
                title: titleUpdate,
                icon: iconUpdate,
                hasCustomTitle: self.panelCustomTitles[filePreviewPanel.id] != nil,
                isDirty: dirtyUpdate
            )
        }
        panelSubscriptions[filePreviewPanel.id] = subscription
    }

    func installAgentSessionPanelSubscription(_ agentPanel: AgentSessionPanel) {
        agentPanel.onDisplayStateChanged = { [weak self, weak agentPanel] newTitle, isDirty in
            guard let self,
                  let agentPanel,
                  let tabId = self.surfaceIdFromPanelId(agentPanel.id) else { return }
            guard let existing = self.bonsplitController.tab(tabId) else { return }

            if self.panelTitles[agentPanel.id] != newTitle {
                self.panelTitles[agentPanel.id] = newTitle
            }
            let resolvedTitle = self.resolvedPanelTitle(panelId: agentPanel.id, fallback: newTitle)
            let titleUpdate: String? = existing.title == resolvedTitle ? nil : resolvedTitle
            let dirtyUpdate: Bool? = existing.isDirty == isDirty ? nil : isDirty
            guard titleUpdate != nil || dirtyUpdate != nil else { return }
            self.bonsplitController.updateTab(
                tabId,
                title: titleUpdate,
                hasCustomTitle: self.panelCustomTitles[agentPanel.id] != nil,
                isDirty: dirtyUpdate
            )
        }
        agentSessionPanelCallbackIds.insert(agentPanel.id)
    }

    func discardAgentSessionPanelSubscription(panelId: UUID, panel: (any Panel)?) {
        if let agentPanel = panel as? AgentSessionPanel {
            agentPanel.onDisplayStateChanged = nil
        }
        agentSessionPanelCallbackIds.remove(panelId)
    }

    func browserRemoteWorkspaceStatusSnapshot() -> BrowserRemoteWorkspaceStatus? {
        guard let target = remoteDisplayTarget else { return nil }
        return BrowserRemoteWorkspaceStatus(
            target: target,
            connectionState: remoteConnectionState,
            heartbeatCount: remoteHeartbeatCount,
            lastHeartbeatAt: remoteLastHeartbeatAt
        )
    }

    func applyBrowserRemoteWorkspaceStatusToPanels() {
        let snapshot = browserRemoteWorkspaceStatusSnapshot()
        for panel in panels.values {
            guard let browserPanel = panel as? BrowserPanel else { continue }
            browserPanel.setRemoteWorkspaceStatus(snapshot)
        }
    }

    // MARK: - Panel Access

    func panel(for surfaceId: TabID) -> (any Panel)? {
        guard let panelId = panelIdFromSurfaceId(surfaceId) else { return nil }
        return panels[panelId]
    }

    func terminalPanel(for panelId: UUID) -> TerminalPanel? {
        panels[panelId] as? TerminalPanel
    }

    func browserPanel(for panelId: UUID) -> BrowserPanel? {
        panels[panelId] as? BrowserPanel
    }

    func markdownPanel(for panelId: UUID) -> MarkdownPanel? {
        panels[panelId] as? MarkdownPanel
    }

    func filePreviewPanel(for panelId: UUID) -> FilePreviewPanel? {
        panels[panelId] as? FilePreviewPanel
    }

    /// The working directory app-level actions (diff viewer, configured commands)
    /// should target for this workspace: the focused panel's tracked directory, then
    /// its terminal's requested directory, then the workspace's current directory.
    /// Returns `nil` when none is known so callers can apply their own fallback.
    ///
    /// This is the focused-panel case of ``configTrackingDirectory(for:)`` (the same
    /// three-tier order); the tiers are spelled out here so the public entry point is
    /// self-contained.
    func resolvedWorkingDirectory() -> String? {
        let candidates = [
            focusedPanelId.flatMap { panelDirectories[$0] },
            focusedPanelId.flatMap { terminalPanel(for: $0)?.requestedWorkingDirectory },
            currentDirectory,
        ]
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    func surfaceKind(for panel: any Panel) -> String {
        switch panel.panelType {
        case .terminal:
            return SurfaceKind.terminal
        case .browser:
            return SurfaceKind.browser
        case .markdown:
            return SurfaceKind.markdown
        case .filePreview:
            return SurfaceKind.filePreview
        case .rightSidebarTool:
            return SurfaceKind.rightSidebarTool
        case .agentSession:
            return SurfaceKind.agentSession
        case .project:
            return SurfaceKind.project
        case .extensionBrowser:
            return SurfaceKind.extensionBrowser
        }
    }

    func resolvedPanelTitle(panelId: UUID, fallback: String) -> String {
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = trimmedFallback.isEmpty ? "Tab" : trimmedFallback
        if let custom = panelCustomTitles[panelId]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        return fallbackTitle
    }

}
