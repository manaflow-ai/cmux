import CmuxControlSocket
import Foundation

/// Shared resolution/scheduling twins for the `ControlSidebarContext`
/// conformance split (`+ControlSidebarContext.swift` / `2` / `3`): byte-faithful
/// re-declarations of the deleted (or file-private) `TerminalController.swift`
/// helpers the lifted v1 sidebar bodies relied on, keyed by the coordinator's
/// Sendable target types instead of the legacy file-private enums.
extension TerminalController {
    /// The worker-lane hop primitive of the sidebar seam: forwards to
    /// `v2MainSync`, so the hop collapses to an inline call when the caller is
    /// already on the main thread, propagates the focus-allowance stack, and
    /// records per-hop timing exactly like every other socket main hop. The
    /// body receives `self` back as its main-actor seam parameter (see the
    /// protocol requirement's doc).
    nonisolated func controlSidebarOnMain<T: Sendable>(
        _ body: @MainActor (any ControlSidebarContext) -> T
    ) -> T {
        v2MainSync {
            body(self)
        }
    }

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
               let otherManager = appEnvironment?.windowRegistry.tabManagerFor(tabId: uuid) {
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
        if let otherManager = appEnvironment?.windowRegistry.tabManagerFor(tabId: id) {
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
    /// body did. `nonisolated` because the bus enqueue is lock-guarded and the
    /// worker-lane telemetry bodies enqueue from the socket-worker thread; the
    /// mutation closure is `@MainActor` so witness call sites' closure
    /// literals (which touch `Workspace`/store state) carry main-actor
    /// isolation even when formed off-main — the bus runs them on the main
    /// actor at drain.
    nonisolated func controlSidebarScheduleMutation(
        target: ControlSidebarTabTarget,
        mutation: @escaping @MainActor (TerminalController, Workspace) -> Void
    ) {
        TerminalMutationBus.shared.enqueueMainActorMutation { [weak self] in
            guard let self, let tab = self.controlSidebarResolveMutationTab(target) else { return }
            mutation(self, tab)
        }
    }

    /// The enqueue halves of the deleted file-private
    /// `schedulePanelMetadataMutation(args:options:missingPanelUsage:mutation:)`
    /// (the parse-level head moved into the coordinator's
    /// `sidebarPanelMutationTarget`): the explicit-scope fast path, then the
    /// report-tab fallback, both deferred on the mutation bus. `nonisolated`
    /// with a `@MainActor` mutation closure, for the same reasons as
    /// `controlSidebarScheduleMutation`.
    nonisolated func controlSidebarSchedulePanelMetadataMutation(
        target: ControlSidebarPanelMutationTarget,
        mutation: @escaping @MainActor (Workspace, UUID) -> Void
    ) {
        if let scope = target.scope {
            TerminalMutationBus.shared.enqueueMainActorMutation { [weak self] in
                guard let self,
                      let tab = self.controlSidebarTabForMutation(id: scope.workspaceID) else {
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
                  let tab = self.controlSidebarResolveTabForReport(tabArg: tabArg) else {
                return
            }
            let validSurfaceIds = Set(tab.panels.keys)
            tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
            guard let surfaceId = surfaceIdFromOptions ?? tab.focusedPanelId else { return }
            guard validSurfaceIds.contains(surfaceId) else { return }
            mutation(tab, surfaceId)
        }
    }

    nonisolated func controlSidebarScheduleScopedDirectoryUpdate(scope: ControlSidebarPanelScope, directory: String, displayLabel: String?) {
        TerminalMutationBus.shared.enqueueReplacingMainActorMutation(
            replaceKey: TerminalMutationReplaceKey(
                tabId: scope.workspaceID,
                surfaceId: scope.panelID,
                kind: .directory
            )
        ) {
            guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: scope.workspaceID),
                  let tab = tabManager.tabs.first(where: { $0.id == scope.workspaceID }) else {
                return
            }
            let validSurfaceIds = Set(tab.panels.keys)
            tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
            guard validSurfaceIds.contains(scope.panelID) else { return }
            self.controlSidebarApplyDirectoryReport(
                tabManager: tabManager,
                tab: tab,
                surfaceId: scope.panelID,
                directory: directory,
                displayLabel: displayLabel
            )
        }
    }

    func controlSidebarUpdateDirectory(
        tabArg: String?,
        panelArg: String?,
        directory: String,
        displayLabel: String?
    ) -> ControlSidebarPanelWriteResolution {
        controlSidebarResolvePanelWrite(
            tabArg: tabArg,
            panelArg: panelArg,
            prune: true,
            requireLiveSurface: true
        ) { tab, surfaceId in
            controlSidebarApplyDirectoryReport(
                tabManager: AppDelegate.shared?.tabManagerFor(tabId: tab.id) ?? tabManager,
                tab: tab,
                surfaceId: surfaceId,
                directory: directory,
                displayLabel: displayLabel
            )
        }
    }

    private func controlSidebarApplyDirectoryReport(
        tabManager: TabManager?,
        tab: Workspace,
        surfaceId: UUID,
        directory: String,
        displayLabel: String?
    ) {
        if let tabManager {
            tabManager.updateReportedSurfaceDirectory(
                tabId: tab.id,
                surfaceId: surfaceId,
                directory: directory,
                displayLabel: displayLabel
            )
        } else if tab.isRemoteTerminalSurface(surfaceId) {
            _ = tab.updateRemotePanelDirectoryWithMetadata(panelId: surfaceId, directory: directory, displayLabel: displayLabel)
        } else {
            _ = tab.updatePanelDirectory(panelId: surfaceId, directory: directory, displayLabel: displayLabel)
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
        guard let tab = controlSidebarResolveTabForReport(tabArg: tabArg) else {
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

        if requireLiveSurface {
            let validSurfaceIds = Set(tab.panels.keys)
            guard validSurfaceIds.contains(surfaceId) else {
                return .panelNotFound(surfaceId)
            }
        }

        write(tab, surfaceId)
        return .done
    }
}
