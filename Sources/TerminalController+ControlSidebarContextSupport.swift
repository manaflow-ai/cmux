import CmuxControlSocket
import Foundation

/// Shared resolution/scheduling twins for the `ControlSidebarContext`
/// conformance split (`+ControlSidebarContext.swift` / `2` / `3`): byte-faithful
/// re-declarations of the deleted (or file-private) `TerminalController.swift`
/// helpers the lifted v1 sidebar bodies relied on, keyed by the coordinator's
/// Sendable target types instead of the legacy file-private enums.
extension TerminalController {
    /// The byte-faithful twin of the deleted file-private
    /// `resolveTabForReport(_:)`, taking the pre-parsed `--tab` option value
    /// instead of re-parsing the full argument string (the parse result is
    /// identical; the coordinator parses once).
    func controlSidebarResolveTabForReport(tabArg: String?) -> Workspace? {
        if let tabArg, !tabArg.isEmpty {
            // First try the local tabManager if available
            if let tabManager = self.tabManager,
               let tab = controlSidebarResolveTab(from: tabArg, tabManager: tabManager) {
                return tab
            }
            // The tab may belong to a different window — search all contexts.
            if let uuid = UUID(uuidString: tabArg.trimmingCharacters(in: .whitespacesAndNewlines)),
               let otherManager = AppDelegate.shared?.tabManagerFor(tabId: uuid) {
                return otherManager.tabs.first(where: { $0.id == uuid })
            }
            return nil
        }
        // Only require self.tabManager when using the selected tab (no --tab arg)
        guard let tabManager = self.tabManager else { return nil }
        guard let selectedId = tabManager.selectedTabId else { return nil }
        return tabManager.tabs.first(where: { $0.id == selectedId })
    }

    /// The byte-faithful twin of the file-private `resolveTab(from:tabManager:)`
    /// (which stays in `TerminalController.swift` for the notification commands).
    func controlSidebarResolveTab(from arg: String, tabManager: TabManager) -> Workspace? {
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            guard let selected = tabManager.selectedTabId else { return nil }
            return tabManager.tabs.first(where: { $0.id == selected })
        }

        if let uuid = UUID(uuidString: trimmed) {
            return tabManager.tabs.first(where: { $0.id == uuid })
        }

        if let index = Int(trimmed), index >= 0, index < tabManager.tabs.count {
            return tabManager.tabs[index]
        }

        return nil
    }

    /// The byte-faithful twin of the file-private `tabForSidebarMutation(id:)`
    /// (which stays in `TerminalController.swift` for the notification
    /// commands): the controller's own TabManager first, then any window's.
    func controlSidebarTabForMutation(id: UUID) -> Workspace? {
        if let tab = tabManager?.tabs.first(where: { $0.id == id }) {
            return tab
        }
        if let otherManager = AppDelegate.shared?.tabManagerFor(tabId: id) {
            return otherManager.tabs.first(where: { $0.id == id })
        }
        return nil
    }

    /// The byte-faithful twin of the file-private `resolveSidebarMutationTab(_:)`
    /// over the coordinator's Sendable target enum.
    func controlSidebarResolveMutationTab(_ target: ControlSidebarTabTarget) -> Workspace? {
        switch target {
        case .selected:
            guard let tabManager = self.tabManager,
                  let selectedId = tabManager.selectedTabId else {
                return nil
            }
            return tabManager.tabs.first(where: { $0.id == selectedId })
        case .workspace(let tabId):
            return controlSidebarTabForMutation(id: tabId)
        case .index(let index):
            guard let tabManager = self.tabManager,
                  index < tabManager.tabs.count else {
                return nil
            }
            return tabManager.tabs[index]
        }
    }

    /// The byte-faithful twin of the deleted file-private
    /// `scheduleSidebarMutation(target:mutation:)`: enqueue on the mutation bus
    /// and resolve the tab inside the deferred closure, exactly as the legacy
    /// body did.
    func controlSidebarScheduleMutation(
        target: ControlSidebarTabTarget,
        mutation: @escaping (TerminalController, Workspace) -> Void
    ) {
        TerminalMutationBus.shared.enqueueMainActorMutation { [weak self] in
            guard let self, let tab = self.controlSidebarResolveMutationTab(target) else { return }
            mutation(self, tab)
        }
    }

    func controlSidebarResolvePanelScopedMutationTab(
        target: ControlSidebarTabTarget,
        panelID: UUID?
    ) -> Workspace? {
        let preferredTab = controlSidebarResolveMutationTab(target)
        guard let panelID else { return preferredTab }
        if let preferredTab, preferredTab.panels[panelID] != nil {
            return preferredTab
        }

        guard case .workspace(let tabID) = target,
              let relocated = AppDelegate.shared?.workspaceContainingPanel(
                  panelId: panelID,
                  preferredWorkspaceId: tabID
              )?.workspace,
              relocated.allowsPanelScopedMutationFallback(fromWorkspaceId: tabID, panelId: panelID) else {
            return nil
        }
        return relocated
    }

    func controlSidebarSchedulePanelScopedMutation(
        target: ControlSidebarTabTarget,
        panelID: UUID?,
        mutation: @escaping (TerminalController, Workspace) -> Void
    ) {
        TerminalMutationBus.shared.enqueueMainActorMutation { [weak self] in
            guard let self,
                  let tab = self.controlSidebarResolvePanelScopedMutationTab(target: target, panelID: panelID) else {
                return
            }
            mutation(self, tab)
        }
    }

    func controlSidebarResolvePanelScopedReportTab(tabArg: String?, panelID: UUID?) -> Workspace? {
        let preferredTab = controlSidebarResolveTabForReport(tabArg: tabArg)
        guard let panelID,
              let tabID = tabArg.flatMap(controlSidebarWorkspaceIDArg) else {
            return preferredTab
        }
        if let preferredTab, preferredTab.panels[panelID] != nil {
            return preferredTab
        }
        return controlSidebarResolvePanelScopedMutationTab(target: .workspace(tabID), panelID: panelID)
    }

    func controlSidebarResolveScopedPanel(
        scope: ControlSidebarPanelScope
    ) -> (tabManager: TabManager, tab: Workspace)? {
        guard let tab = controlSidebarResolvePanelScopedMutationTab(
            target: .workspace(scope.workspaceID),
            panelID: scope.panelID
        ) else {
            return nil
        }
        let resolvedManager = controlSidebarTabManager(for: tab)
        guard let tabManager = resolvedManager else { return nil }
        return (tabManager, tab)
    }

    func controlSidebarTabManager(for tab: Workspace) -> TabManager? {
        AppDelegate.shared?.tabManagerFor(tabId: tab.id) ?? {
            guard let tabManager = self.tabManager,
                  tabManager.tabs.contains(where: { $0.id == tab.id }) else {
                return nil
            }
            return tabManager
        }()
    }

    private func controlSidebarWorkspaceIDArg(_ raw: String) -> UUID? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return UUID(uuidString: trimmed)
    }

    /// The enqueue halves of the deleted file-private
    /// `schedulePanelMetadataMutation(args:options:missingPanelUsage:mutation:)`
    /// (the parse-level head moved into the coordinator's
    /// `sidebarPanelMutationTarget`): the explicit-scope fast path, then the
    /// report-tab fallback, both deferred on the mutation bus.
    func controlSidebarSchedulePanelMetadataMutation(
        target: ControlSidebarPanelMutationTarget,
        mutation: @escaping (Workspace, UUID) -> Void
    ) {
        if let scope = target.scope {
            TerminalMutationBus.shared.enqueueMainActorMutation { [weak self] in
                guard let self,
                      let (_, tab) = self.controlSidebarResolveScopedPanel(scope: scope) else {
                    return
                }
                let validSurfaceIds = Set(tab.panels.keys)
                tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
                guard validSurfaceIds.contains(scope.panelID) else { return }
                mutation(tab, scope.panelID)
            }
            return
        }

        let tabArg = target.tabArg
        let surfaceIdFromOptions = target.panelID
        TerminalMutationBus.shared.enqueueMainActorMutation { [weak self] in
            guard let self,
                  let tab = self.controlSidebarResolvePanelScopedReportTab(
                      tabArg: tabArg,
                      panelID: surfaceIdFromOptions
                  ) else {
                return
            }
            let validSurfaceIds = Set(tab.panels.keys)
            tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
            guard let surfaceId = surfaceIdFromOptions ?? tab.focusedPanelId else { return }
            guard validSurfaceIds.contains(surfaceId) else { return }
            mutation(tab, surfaceId)
        }
    }

    /// The shared head of the synchronous panel-targeted sidebar writes
    /// (`report_ports` / `clear_ports` / `report_pwd` / `report_shell_state` /
    /// `report_tty` / `ports_kick` fallback paths): resolves the tab, then the
    /// panel argument, preserving the legacy check order. `prune` mirrors which
    /// legacy bodies pruned before resolving; `requireLiveSurface` mirrors which
    /// bodies membership-checked the resolved surface (`ports_kick` did not).
    func controlSidebarResolvePanelWrite(
        tabArg: String?,
        panelArg: String?,
        prune: Bool,
        requireLiveSurface: Bool,
        write: (Workspace, UUID) -> Void
    ) -> ControlSidebarPanelWriteResolution {
        let preferredTab = controlSidebarResolveTabForReport(tabArg: tabArg)
        let fallbackPanelID = panelArg.flatMap(controlSidebarWorkspaceIDArg)
        guard var tab = preferredTab ?? fallbackPanelID.flatMap({
            controlSidebarResolvePanelScopedReportTab(tabArg: tabArg, panelID: $0)
        }) else {
            return .tabNotFound
        }

        if prune {
            let validSurfaceIds = Set(tab.panels.keys)
            tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
        }

        let surfaceId: UUID
        if let panelArg {
            if panelArg.isEmpty {
                return .missingPanelArg
            }
            guard let parsedId = UUID(uuidString: panelArg) else {
                return .invalidPanelArg(panelArg)
            }
            surfaceId = parsedId
        } else {
            guard let focused = tab.focusedPanelId else {
                return .noFocusedPanel
            }
            surfaceId = focused
        }

        if tab.panels[surfaceId] == nil,
           let fallbackTab = controlSidebarResolvePanelScopedReportTab(tabArg: tabArg, panelID: surfaceId),
           fallbackTab.id != tab.id {
            tab = fallbackTab
            if prune {
                let fallbackSurfaceIds = Set(fallbackTab.panels.keys)
                fallbackTab.pruneSurfaceMetadata(validSurfaceIds: fallbackSurfaceIds)
            }
        }

        if requireLiveSurface {
            guard Set(tab.panels.keys).contains(surfaceId) else {
                return .panelNotFound(surfaceId)
            }
        }

        write(tab, surfaceId)
        return .done
    }
}
