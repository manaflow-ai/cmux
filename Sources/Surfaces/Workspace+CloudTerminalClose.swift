import AppKit
import Bonsplit
import CmuxSettings
import Foundation

/// Closing a pane that projects a cloud terminal is two different verbs: detach
/// (the pane goes, the terminal keeps running in the machine's cmux-tui session)
/// and kill (`terminal <id> close` ends the process, then the pane goes). Every
/// entrypoint — Cmd+W, the tab close button, the pane close button, the tab
/// context menu, the terminal context menu — lands on `detachCloudTerminal` or
/// `killCloudTerminal`; `app.closeCloudTerminal` decides which one a plain close
/// means, and `ask` prompts (with "Remember my choice" writing the setting).
extension Workspace {
    struct CloudTerminalPane: Equatable {
        let tabId: TabID
        let panelId: UUID
        let resource: SurfaceResource
    }

    /// The cloud terminal a tab projects, when it does.
    func cloudTerminalPane(forTab tabId: TabID) -> CloudTerminalPane? {
        guard let panelId = panelIdFromSurfaceId(tabId),
              let resource = cloudProjectedResource(forPanel: panelId),
              resource.kind == .terminal else { return nil }
        return CloudTerminalPane(tabId: tabId, panelId: panelId, resource: resource)
    }

    func cloudTerminalPane(forPanel panelId: UUID) -> CloudTerminalPane? {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return nil }
        return cloudTerminalPane(forTab: tabId)
    }

    func configureCloudTerminalContextMenuAvailability() {
        bonsplitController.tabContextCloudTerminalAvailabilityProvider = { [weak self] tabId, _ in
            self?.cloudTerminalPane(forTab: tabId) != nil
        }
    }

    // MARK: - Close gates

    /// The tab close gate (Cmd+W, the tab close button, Close Tab in the menu).
    /// Returns true when the close was taken over: the decision is made here
    /// (or asked for) and the pane is closed again through the decided path,
    /// so the caller must return `false` to bonsplit.
    func interceptCloudTerminalTabClose(
        tab: Bonsplit.Tab,
        tabCloseButton: Bool?,
        explicitUserClose: Bool
    ) -> Bool {
        if cloudTerminalCloseDecidedTabIds.remove(tab.id) != nil { return false }
        guard let pane = cloudTerminalPane(forTab: tab.id) else { return false }
        let reclose = CloudTerminalReclose(tabCloseButton: tabCloseButton, explicitUserClose: explicitUserClose)
        switch CloudTerminalClosePolicy.resolution(for: CloudTerminalCloseStore(defaults: closeTabWarningDefaults).action) {
        case .detach:
            return false
        case .kill:
            killCloudTerminals([pane], reclose: reclose)
            return true
        case .prompt:
            promptCloudTerminalClose(panes: [pane], reclose: reclose) { [weak self] decision in
                guard let self else { return }
                switch decision {
                case .detach:
                    _ = self.requestCloseCloudTerminalTab(pane.tabId, reclose: reclose)
                case .kill:
                    self.killCloudTerminals([pane], reclose: reclose)
                case .cancel:
                    self.clearCloseHistoryEligibility(tabId: pane.tabId, panelId: pane.panelId)
                }
            }
            return true
        }
    }

    /// The pane close gate: every cloud terminal in the pane gets the same
    /// answer. Returns true when the close was taken over (caller returns `false`).
    func interceptCloudTerminalPaneClose(pane: PaneID, tabs: [Bonsplit.Tab]) -> Bool {
        let tabIds = tabs.map(\.id)
        if cloudTerminalCloseDecidedPaneIds.remove(pane.id) != nil { return false }
        let cloudPanes = tabs.compactMap { tab -> CloudTerminalPane? in
            guard !isForceClosingTab(tab.id) else { return nil }
            return cloudTerminalPane(forTab: tab.id)
        }
        guard !cloudPanes.isEmpty else { return false }
        switch CloudTerminalClosePolicy.resolution(for: CloudTerminalCloseStore(defaults: closeTabWarningDefaults).action) {
        case .detach:
            return false
        case .kill:
            killCloudTerminals(cloudPanes, reclose: nil) { [weak self] in
                self?.forceClosePaneAfterCloudTerminalDecision(pane, tabIds: tabIds)
            }
            return true
        case .prompt:
            promptCloudTerminalClose(panes: cloudPanes, reclose: nil) { [weak self] decision in
                guard let self else { return }
                switch decision {
                case .detach:
                    self.forceClosePaneAfterCloudTerminalDecision(pane, tabIds: tabIds)
                case .kill:
                    self.killCloudTerminals(cloudPanes, reclose: nil) { [weak self] in
                        self?.forceClosePaneAfterCloudTerminalDecision(pane, tabIds: tabIds)
                    }
                case .cancel:
                    break
                }
            }
            return true
        }
    }

    // MARK: - Verbs (menus)

    /// "Detach Terminal": close the pane, keep the terminal running.
    func detachCloudTerminal(panelId: UUID) {
        guard let pane = cloudTerminalPane(forPanel: panelId) else { return }
        _ = requestCloseCloudTerminalTab(pane.tabId, reclose: CloudTerminalReclose(tabCloseButton: nil, explicitUserClose: true))
    }

    /// "Kill Process": end the terminal on its machine, then close the pane.
    func killCloudTerminal(panelId: UUID) {
        guard let pane = cloudTerminalPane(forPanel: panelId) else { return }
        killCloudTerminals([pane], reclose: CloudTerminalReclose(tabCloseButton: nil, explicitUserClose: true))
    }

    // MARK: - Internals

    private func promptCloudTerminalClose(
        panes: [CloudTerminalPane],
        reclose: CloudTerminalReclose?,
        completion: @escaping @MainActor (CloudTerminalCloseDecision) -> Void
    ) {
        let tabIds = panes.map(\.tabId)
        guard cloudTerminalClosePromptTabIds.isDisjoint(with: tabIds) else { return }
        let confirmationManager = owningTabManager
            ?? AppDelegate.shared?.tabManagerFor(tabId: id)
            ?? AppDelegate.shared?.tabManager
        if let confirmationManager, !confirmationManager.beginCloseConfirmationSession() {
            for pane in panes { clearCloseHistoryEligibility(tabId: pane.tabId, panelId: pane.panelId) }
            return
        }
        cloudTerminalClosePromptTabIds.formUnion(tabIds)
        let prompt = CloudTerminalClosePrompt(
            terminalNames: panes.map { cloudTerminalDisplayName($0) },
            machineName: cloudMachineDisplayName(panes[0].resource.id.machine)
        )
        let store = CloudTerminalCloseStore(defaults: closeTabWarningDefaults)
        // Present on the next main-actor turn: bonsplit is still inside its close
        // request, and a modal loop from within that callback re-enters it.
        Task { @MainActor [weak self] in
            defer {
                self?.cloudTerminalClosePromptTabIds.subtract(tabIds)
                confirmationManager?.endCloseConfirmationSession()
            }
            guard let self else { return }
            // Anything that disappeared while the prompt was queued is not closed twice.
            guard panes.allSatisfy({ self.panels[$0.panelId] != nil }) else { return }
            let result = CloudTerminalCloseAlertPresenter.present(prompt: prompt)
            if let remembered = CloudTerminalClosePolicy.actionToRemember(decision: result.decision, remember: result.remember) {
                store.setAction(remembered)
            }
            completion(result.decision)
        }
    }

    /// Ends each terminal on its machine, then closes the local panes. The
    /// provider force-closes every pane projecting a killed terminal except a
    /// workspace's last surface, which is closed through the normal path so the
    /// last-surface preference (close workspace vs keep it open) still applies.
    private func killCloudTerminals(
        _ panes: [CloudTerminalPane],
        reclose: CloudTerminalReclose?,
        then followUp: (@MainActor () -> Void)? = nil
    ) {
        let catalog = SurfaceCatalog.shared
        Task { @MainActor [weak self] in
            for pane in panes {
                guard let provider = catalog.provider(for: pane.resource.id.machine) else {
                    CloudTerminalCloseAlertPresenter.presentKillFailure(
                        terminalName: self?.cloudTerminalDisplayName(pane) ?? pane.resource.id.key,
                        error: SurfaceCatalogError.noProvider(pane.resource.id.machine)
                    )
                    return
                }
                do {
                    try await provider.closeTerminal(pane.resource.id)
                } catch {
                    CloudTerminalCloseAlertPresenter.presentKillFailure(
                        terminalName: self?.cloudTerminalDisplayName(pane) ?? pane.resource.id.key,
                        error: error
                    )
                    return
                }
                guard let self, self.panels[pane.panelId] != nil,
                      let tabId = self.surfaceIdFromPanelId(pane.panelId) else { continue }
                _ = self.requestCloseCloudTerminalTab(
                    tabId,
                    reclose: reclose ?? CloudTerminalReclose(tabCloseButton: nil, explicitUserClose: true)
                )
            }
            followUp?()
        }
    }

    private func cloudTerminalDisplayName(_ pane: CloudTerminalPane) -> String {
        let panelTitle = panels[pane.panelId]?.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !panelTitle.isEmpty { return panelTitle }
        let title = pane.resource.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? pane.resource.id.key : title
    }

    private func cloudMachineDisplayName(_ machine: SurfaceMachineID) -> String {
        SurfaceCatalog.shared.provider(for: machine)?.info.name ?? machine.rawValue
    }
}

/// How a close is re-requested after the decision, so the second pass through
/// the close gate keeps the original gesture's meaning (tab close button vs
/// shortcut, explicit user close vs programmatic).
struct CloudTerminalReclose: Equatable, Sendable {
    let tabCloseButton: Bool?
    let explicitUserClose: Bool
}
