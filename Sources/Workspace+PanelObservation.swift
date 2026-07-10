import Foundation

// Panel tab-metadata observation for the main workspace area: keeps Bonsplit
// tab chrome (title, favicon, loading, mute, dirty state) in sync with each
// panel's Observation-tracked state via `observeTrackedValue`. Extracted from
// `Workspace.swift`; the workspace owns the token lifecycle through
// `panelSubscriptions`.
extension Workspace {
    private struct BrowserPanelTabObservationState: Equatable {
        let pageTitle: String
        let currentURL: URL?
        let isLoading: Bool
        let faviconPNGData: Data?
        let isMuted: Bool

        static let empty = BrowserPanelTabObservationState(
            pageTitle: "",
            currentURL: nil,
            isLoading: false,
            faviconPNGData: nil,
            isMuted: false
        )
    }

    func installBrowserPanelSubscription(_ browserPanel: BrowserPanel) {
        let subscription = observeTrackedValue { [weak browserPanel] in
            guard let browserPanel else { return BrowserPanelTabObservationState.empty }
            return BrowserPanelTabObservationState(
                pageTitle: browserPanel.pageTitle,
                currentURL: browserPanel.currentURL,
                isLoading: browserPanel.isLoading,
                faviconPNGData: browserPanel.faviconPNGData,
                isMuted: browserPanel.isMuted
            )
        } onChange: { [weak self, weak browserPanel] state in
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
            let faviconUpdate: Data?? = existing.iconImageData == state.faviconPNGData ? nil : .some(state.faviconPNGData)
            let loadingUpdate: Bool? = existing.isLoading == state.isLoading ? nil : state.isLoading
            let mutedUpdate: Bool? = existing.isAudioMuted == state.isMuted ? nil : state.isMuted
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
        browserPanel.onMediaActivityChanged = { [weak self, weak browserPanel] _ in
            guard let self, let browserPanel else { return }
            self.handleBrowserMediaActivityChanged(browserPanel)
        }
        handleBrowserMediaActivityChanged(browserPanel)
        publishBrowserOpenTabSuggestion(for: browserPanel)
        setPreferredBrowserProfileID(browserPanel.profileID)
    }

    private struct MarkdownPanelTabObservationState: Equatable {
        let displayTitle: String
        let isDirty: Bool

        static let empty = MarkdownPanelTabObservationState(displayTitle: "", isDirty: false)
    }

    func installMarkdownPanelSubscription(_ markdownPanel: MarkdownPanel) {
        let subscription = observeTrackedValue { [weak markdownPanel] in
            guard let markdownPanel else { return MarkdownPanelTabObservationState.empty }
            return MarkdownPanelTabObservationState(
                displayTitle: markdownPanel.displayTitle,
                isDirty: markdownPanel.isDirty
            )
        } onChange: { [weak self, weak markdownPanel] state in
                guard let self,
                      let markdownPanel,
                      let tabId = self.surfaceIdFromPanelId(markdownPanel.id) else { return }
                guard let existing = self.bonsplitController.tab(tabId) else { return }

                if self.panelTitles[markdownPanel.id] != state.displayTitle {
                    self.panelTitles[markdownPanel.id] = state.displayTitle
                }
                let resolvedTitle = self.resolvedPanelTitle(panelId: markdownPanel.id, fallback: state.displayTitle)
                let titleUpdate: String? = existing.title == resolvedTitle ? nil : resolvedTitle
                let dirtyUpdate: Bool? = existing.isDirty == state.isDirty ? nil : state.isDirty
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

    private struct FilePreviewPanelTabObservationState: Equatable {
        let displayTitle: String
        let isDirty: Bool
        let displayIcon: String?

        static let empty = FilePreviewPanelTabObservationState(
            displayTitle: "",
            isDirty: false,
            displayIcon: nil
        )
    }

    func installFilePreviewPanelSubscription(_ filePreviewPanel: FilePreviewPanel) {
        let subscription = observeTrackedValue { [weak filePreviewPanel] in
            guard let filePreviewPanel else { return FilePreviewPanelTabObservationState.empty }
            return FilePreviewPanelTabObservationState(
                displayTitle: filePreviewPanel.displayTitle,
                isDirty: filePreviewPanel.isDirty,
                displayIcon: filePreviewPanel.displayIcon
            )
        } onChange: { [weak self, weak filePreviewPanel] state in
            guard let self,
                  let filePreviewPanel,
                  let tabId = self.surfaceIdFromPanelId(filePreviewPanel.id) else { return }
            guard let existing = self.bonsplitController.tab(tabId) else { return }

            if self.panelTitles[filePreviewPanel.id] != state.displayTitle {
                self.panelTitles[filePreviewPanel.id] = state.displayTitle
            }
            let resolvedTitle = self.resolvedPanelTitle(panelId: filePreviewPanel.id, fallback: state.displayTitle)
            let resolvedIcon = RenderableSystemSymbol.resolvedSurfaceTabIcon(state.displayIcon)
            let titleUpdate: String? = existing.title == resolvedTitle ? nil : resolvedTitle
            let iconUpdate: String?? = existing.icon == resolvedIcon ? nil : .some(resolvedIcon)
            let dirtyUpdate: Bool? = existing.isDirty == state.isDirty ? nil : state.isDirty
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
}
