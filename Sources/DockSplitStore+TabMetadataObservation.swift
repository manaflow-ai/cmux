import Foundation

// Dock tab metadata subscriptions: keeps Bonsplit tab chrome (title, favicon,
// loading, mute) in sync with the owning panel's Observation-tracked state.
// Extracted from `DockSplitStore.swift`; the store owns the token lifecycle
// through `panelCancellables` (torn down in `reconcilePanels`).
extension DockSplitStore {
    private struct DockBrowserTabObservationState: Equatable {
        let pageTitle: String
        let isLoading: Bool
        let faviconPNGData: Data?
        let isMuted: Bool

        static let empty = DockBrowserTabObservationState(
            pageTitle: "",
            isLoading: false,
            faviconPNGData: nil,
            isMuted: false
        )
    }

    private struct DockTerminalTabObservationState: Equatable {
        let title: String

        static let empty = DockTerminalTabObservationState(title: "")
    }

    func installSubscription(for panel: any Panel, tracksTerminalTitle: Bool) {
        if let browser = panel as? BrowserPanel {
            let cancellable = observeTrackedValue { [weak browser] in
                guard let browser else { return DockBrowserTabObservationState.empty }
                return DockBrowserTabObservationState(
                    pageTitle: browser.pageTitle,
                    isLoading: browser.isLoading,
                    faviconPNGData: browser.faviconPNGData,
                    isMuted: browser.isMuted
                )
            } onChange: { [weak self, weak browser] _ in
                guard let self, let browser, let tabId = self.surfaceId(forPanelId: browser.id),
                      let existing = self.bonsplitController.tab(tabId) else { return }
                // Only push fields that actually changed. CombineLatest4 fires on
                // ANY of the four publishers, so an `isLoading` flicker during a
                // page load would otherwise re-publish the (unchanged) title and
                // favicon, mutating the @Observable BonsplitController and
                // re-rendering the Dock tree for nothing. Mirrors the main area's
                // guarded path in Workspace.installBrowserPanelSubscription.
                let resolvedTitle = browser.displayTitle
                let favicon = browser.faviconPNGData
                let titleUpdate: String? = existing.title == resolvedTitle ? nil : resolvedTitle
                let faviconUpdate: Data?? = existing.iconImageData == favicon ? nil : .some(favicon)
                let loadingUpdate: Bool? = existing.isLoading == browser.isLoading ? nil : browser.isLoading
                let mutedUpdate: Bool? = existing.isAudioMuted == browser.isMuted ? nil : browser.isMuted
                guard titleUpdate != nil || faviconUpdate != nil || loadingUpdate != nil || mutedUpdate != nil else { return }
                self.bonsplitController.updateTab(
                    tabId,
                    title: titleUpdate,
                    iconImageData: faviconUpdate,
                    isLoading: loadingUpdate,
                    isAudioMuted: mutedUpdate
                )
            }
            panelCancellables[panel.id] = cancellable
        } else if tracksTerminalTitle, let terminal = panel as? TerminalPanel {
            let cancellable = observeTrackedValue { [weak terminal] in
                guard let terminal else { return DockTerminalTabObservationState.empty }
                return DockTerminalTabObservationState(title: terminal.title)
            } onChange: { [weak self, weak terminal] _ in
                    guard let self, let terminal, let tabId = self.surfaceId(forPanelId: terminal.id),
                          let existing = self.bonsplitController.tab(tabId) else { return }
                    // Skip the @Observable mutation when the resolved title is
                    // unchanged, so a terminal re-emitting the same title does not
                    // re-render the Dock tree.
                    let resolvedTitle = terminal.displayTitle
                    guard existing.title != resolvedTitle else { return }
                    self.bonsplitController.updateTab(tabId, title: resolvedTitle)
                }
            panelCancellables[panel.id] = cancellable
        }
    }
}
