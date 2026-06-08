import AppKit
import Bonsplit
import Darwin
import Foundation

extension Workspace {
    private static let structuredAgentHookStatusKeys = AgentHibernationLifecycleStatusKeys.allowedStatusKeys
    private static let managedSubagentEnvironmentKey = "CMUX_AGENT_MANAGED_SUBAGENT"
    private static let truthyStartupEnvironmentValues: Set<String> = ["1", "true", "yes", "on", "enabled"]

    func agentRuntimeState(forPanelId panelId: UUID) -> DetachedAgentRuntimeState? {
        let pidKeys = agentPIDKeysByPanelId[panelId] ?? []

        var agentPIDsForPanel: [String: pid_t] = [:]
        var statusEntriesForPanel: [String: SidebarStatusEntry] = [:]
        for key in pidKeys {
            if let pid = agentPIDs[key] {
                agentPIDsForPanel[key] = pid
            }
            let statusKey = agentStatusKey(forAgentPIDKey: key)
            if let statusEntry = statusEntries[statusKey] {
                statusEntriesForPanel[statusKey] = statusEntry
            }
        }
        guard !statusEntriesForPanel.isEmpty || !agentPIDsForPanel.isEmpty || !pidKeys.isEmpty else { return nil }
        return DetachedAgentRuntimeState(
            panelId: panelId,
            statusEntries: statusEntriesForPanel,
            agentPIDs: agentPIDsForPanel,
            agentPIDKeys: pidKeys
        )
    }

    private func agentStatusKey(forAgentPIDKey key: String) -> String {
        if statusEntries[key] != nil {
            return key
        }
        guard let dotIndex = key.firstIndex(of: ".") else {
            return key
        }
        return String(key[..<dotIndex])
    }

    // MARK: - Dynamic agent tab icons

    private static let agentTabIconResolver = AgentTabIconResolver()

    /// Status keys attributed to `panelId` from both the live agent-hook signal and the periodic
    /// process scan, used to choose the pane's brand tab icon.
    private func agentTabIconStatusKeys(forPanelId panelId: UUID) -> Set<String> {
        var statusKeys = Set<String>()
        for key in agentPIDKeysByPanelId[panelId] ?? [] {
            statusKeys.insert(agentStatusKey(forAgentPIDKey: key))
        }
        statusKeys.formUnion(agentTabIconScanStatusKeysByPanelId[panelId] ?? [])
        return statusKeys
    }

    /// Recomputes and applies the brand tab icon for `panelId`, resetting to the default terminal
    /// icon when no recognized agent is active. No-op for non-terminal panels.
    func refreshAgentTabIcon(forPanelId panelId: UUID) {
        guard panels[panelId] is TerminalPanel else { return }
        let statusKeys = agentTabIconStatusKeys(forPanelId: panelId)
        let assetName = Self.agentTabIconResolver.assetName(forStatusKeys: statusKeys)
        applyAgentTabIcon(assetName: assetName, toPanelId: panelId)
    }

    /// Updates the panel's Bonsplit tab to show `assetName`'s logo, or the default terminal icon
    /// when `assetName` is `nil`. Skips the update when nothing changed.
    private func applyAgentTabIcon(assetName: String?, toPanelId panelId: UUID) {
        let appliedSentinel = assetName ?? ""
        guard appliedAgentTabIconAssetNameByPanelId[panelId] != appliedSentinel else { return }
        guard let tabId = surfaceIdFromPanelId(panelId) else { return }
        if let assetName, let pngData = agentTabIconPNGData(forAssetName: assetName) {
            bonsplitController.updateTab(tabId, iconImageData: .some(pngData))
        } else {
            bonsplitController.updateTab(tabId, icon: .some("terminal.fill"), iconImageData: .some(nil))
        }
        appliedAgentTabIconAssetNameByPanelId[panelId] = appliedSentinel
    }

    private func agentTabIconPNGData(forAssetName assetName: String) -> Data? {
        if let cached = agentTabIconPNGCacheByAssetName[assetName] {
            return cached
        }
        guard let image = NSImage(named: assetName),
              let pngData = Self.makeAgentTabIconPNGData(from: image, targetPx: 32) else {
            return nil
        }
        agentTabIconPNGCacheByAssetName[assetName] = pngData
        return pngData
    }

    /// Rasterizes `image` into a square, aspect-fit PNG suitable for a Bonsplit raster tab icon.
    private static func makeAgentTabIconPNGData(from image: NSImage, targetPx: Int) -> Data? {
        let px = max(16, min(128, targetPx))
        let size = NSSize(width: px, height: px)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: px,
            pixelsHigh: px,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let context = NSGraphicsContext(bitmapImageRep: rep)
        context?.imageInterpolation = .high
        context?.shouldAntialias = true
        NSGraphicsContext.current = context
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()
        let sourceSize = image.size
        let scale = min(size.width / max(1, sourceSize.width), size.height / max(1, sourceSize.height))
        let drawSize = NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let drawRect = NSRect(
            x: round((size.width - drawSize.width) / 2.0),
            y: round((size.height - drawSize.height) / 2.0),
            width: round(drawSize.width),
            height: round(drawSize.height)
        )
        image.draw(
            in: drawRect,
            from: NSRect(origin: .zero, size: sourceSize),
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        return rep.representation(using: .png, properties: [:])
    }

    /// Applies the result of a periodic agent process scan, replacing each terminal pane's
    /// scan-derived status keys and refreshing any whose brand icon changed. `statusKeysBySurfaceID`
    /// is keyed by cmux surface ID, which equals the pane's panel ID. Covers agents without a
    /// `set_agent_pid` hook (Augment, Codex, Grok, Antigravity).
    func applyAgentTabIconScan(statusKeysBySurfaceID: [UUID: Set<String>]) {
        for (panelId, panel) in panels where panel is TerminalPanel {
            let desired = statusKeysBySurfaceID[panelId] ?? []
            let current = agentTabIconScanStatusKeysByPanelId[panelId] ?? []
            guard desired != current else { continue }
            if desired.isEmpty {
                agentTabIconScanStatusKeysByPanelId.removeValue(forKey: panelId)
            } else {
                agentTabIconScanStatusKeysByPanelId[panelId] = desired
            }
            refreshAgentTabIcon(forPanelId: panelId)
        }
    }

    private func hasAgentRuntime(forStatusKey statusKey: String) -> Bool {
        for key in agentPIDs.keys where agentStatusKey(forAgentPIDKey: key) == statusKey {
            return true
        }
        for key in agentPIDPanelIdsByKey.keys where agentStatusKey(forAgentPIDKey: key) == statusKey {
            return true
        }
        return false
    }

    private func removeAgentPIDOwnership(key: String) {
        if let previousPanelId = agentPIDPanelIdsByKey[key] {
            agentPIDKeysByPanelId[previousPanelId]?.remove(key)
            if agentPIDKeysByPanelId[previousPanelId]?.isEmpty == true {
                agentPIDKeysByPanelId.removeValue(forKey: previousPanelId)
            }
            agentPIDPanelIdsByKey.removeValue(forKey: key)
        }
    }

    private func recordAgentPIDOwnership(key: String, panelId: UUID) {
        if let previousPanelId = agentPIDPanelIdsByKey[key], previousPanelId != panelId {
            removeAgentPIDOwnership(key: key)
        }
        if isStructuredAgentHookPIDKey(key) {
            let statusKey = agentStatusKey(forAgentPIDKey: key)
            let stalePanelKeys = agentPIDKeysByPanelId[panelId]?.filter {
                $0 != key &&
                isStructuredAgentHookPIDKey($0) &&
                agentStatusKey(forAgentPIDKey: $0) != statusKey
            } ?? []
            for staleKey in stalePanelKeys {
                _ = clearAgentPID(key: staleKey, panelId: panelId, clearStatus: true, refreshPorts: false)
            }
        }
        agentPIDPanelIdsByKey[key] = panelId
        agentPIDKeysByPanelId[panelId, default: []].insert(key)
    }

    @discardableResult
    private func clearOtherStructuredAgentRuntimes(onPanel panelId: UUID, keeping retainedKey: String) -> Bool {
        guard isStructuredAgentHookPIDKey(retainedKey) else { return false }
        let staleKeys = agentPIDKeysByPanelId[panelId] ?? []
        var didChange = false
        for staleKey in staleKeys where staleKey != retainedKey && isStructuredAgentHookPIDKey(staleKey) {
            if clearAgentPID(key: staleKey, panelId: panelId, clearStatus: true, refreshPorts: false) {
                didChange = true
            }
        }
        return didChange
    }

    @discardableResult
    func recordAgentPID(key: String, pid: pid_t, panelId: UUID?, refreshPorts: Bool = true) -> Bool {
        var didClearOtherStructuredAgentRuntime = false
        if let panelId {
            didClearOtherStructuredAgentRuntime = clearOtherStructuredAgentRuntimes(onPanel: panelId, keeping: key)
        }
        agentPIDs[key] = pid
        if let panelId {
            recordAgentPIDOwnership(key: key, panelId: panelId)
        } else {
            removeAgentPIDOwnership(key: key)
        }
        if refreshPorts {
            refreshTrackedAgentPorts()
        }
        if let panelId {
            refreshAgentTabIcon(forPanelId: panelId)
        }
        return didClearOtherStructuredAgentRuntime
    }

    func suppressesRawTerminalNotification(panelId: UUID?) -> Bool {
        guard let panelId else {
            return false
        }

        if AgentSubagentNotificationSettings.suppressNotifications(),
           terminalPanelHasManagedSubagentStartupEnvironment(panelId: panelId) {
            return true
        }

        let panelKeys = agentPIDKeysByPanelId[panelId] ?? []
        return panelKeys.contains { isStructuredAgentHookPIDKey($0) }
    }

    private func terminalPanelHasManagedSubagentStartupEnvironment(panelId: UUID) -> Bool {
        guard let rawValue = terminalPanel(for: panelId)?
            .surface
            .startupEnvironmentValue(Self.managedSubagentEnvironmentKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            return false
        }
        return Self.truthyStartupEnvironmentValues.contains(rawValue)
    }

    func sidebarStatusEntriesVisibleForDisplay() -> [SidebarStatusEntry] {
        let visibleStructuredStatusKeys = visibleStructuredAgentStatusKeysByPanel()
        return statusEntries.values.filter { entry in
            shouldDisplaySidebarStatusEntry(entry, visibleStructuredStatusKeys: visibleStructuredStatusKeys)
        }
    }

    private func shouldDisplaySidebarStatusEntry(
        _ entry: SidebarStatusEntry,
        visibleStructuredStatusKeys: Set<String>
    ) -> Bool {
        guard Self.structuredAgentHookStatusKeys.contains(entry.key) else {
            return true
        }
        return visibleStructuredStatusKeys.contains(entry.key)
    }

    private func visibleStructuredAgentStatusKeysByPanel() -> Set<String> {
        var statusKeysByPanelId: [UUID: Set<String>] = [:]
        for (key, panelId) in agentPIDPanelIdsByKey
        where panels[panelId] != nil {
            let statusKey = agentStatusKey(forAgentPIDKey: key)
            guard Self.structuredAgentHookStatusKeys.contains(statusKey),
                  statusEntries[statusKey] != nil else {
                continue
            }
            statusKeysByPanelId[panelId, default: []].insert(statusKey)
        }
        var visibleStatusKeys = Set<String>()
        for statusKeys in statusKeysByPanelId.values {
            let winningEntry = statusKeys.compactMap { statusEntries[$0] }.max {
                isSidebarStatusEntryLessCurrent($0, than: $1)
            }
            if let winningEntry {
                visibleStatusKeys.insert(winningEntry.key)
            }
        }

        for key in agentPIDs.keys where agentPIDPanelIdsByKey[key] == nil {
            let statusKey = agentStatusKey(forAgentPIDKey: key)
            guard Self.structuredAgentHookStatusKeys.contains(statusKey),
                  statusEntries[statusKey] != nil else {
                continue
            }
            visibleStatusKeys.insert(statusKey)
        }

        return visibleStatusKeys
    }

    private func isSidebarStatusEntryLessCurrent(
        _ lhs: SidebarStatusEntry,
        than rhs: SidebarStatusEntry
    ) -> Bool {
        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp < rhs.timestamp
        }
        if lhs.priority != rhs.priority {
            return lhs.priority < rhs.priority
        }
        return lhs.key > rhs.key
    }

    private func isStructuredAgentHookPIDKey(_ key: String) -> Bool {
        Self.structuredAgentHookStatusKeys.contains(agentStatusKey(forAgentPIDKey: key))
    }

    @discardableResult
    func clearAgentPID(
        key: String,
        panelId: UUID? = nil,
        clearStatus: Bool = false,
        refreshPorts: Bool = true
    ) -> Bool {
        let ownedPanelId = agentPIDPanelIdsByKey[key]
        if let panelId, let ownedPanelId, ownedPanelId != panelId {
            return false
        }
        let statusKeyToClear = clearStatus ? agentStatusKey(forAgentPIDKey: key) : nil

        var didChange = false
        if agentPIDs.removeValue(forKey: key) != nil {
            didChange = true
        }
        if ownedPanelId != nil {
            removeAgentPIDOwnership(key: key)
            didChange = true
        }
        if let lifecyclePanelId = ownedPanelId ?? panelId {
            let lifecycleStatusKey = agentStatusKey(forAgentPIDKey: key)
            if clearAgentLifecycle(key: lifecycleStatusKey, panelId: lifecyclePanelId) {
                didChange = true
            }
        }
        if let statusKeyToClear,
           !hasAgentRuntime(forStatusKey: statusKeyToClear),
           statusEntries.removeValue(forKey: statusKeyToClear) != nil {
            didChange = true
        }
        if didChange, refreshPorts {
            refreshTrackedAgentPorts()
        }
        if let iconPanelId = ownedPanelId ?? panelId {
            refreshAgentTabIcon(forPanelId: iconPanelId)
        }
        return didChange
    }

    func refreshTrackedAgentPorts() {
        agentListeningPorts.removeAll(keepingCapacity: false)
        let remainingAgentPIDs = Set(agentPIDs.values.compactMap { $0 > 0 ? Int($0) : nil })
        PortScanner.shared.refreshAgentPorts(workspaceId: id, agentPIDs: remainingAgentPIDs)
        recomputeListeningPorts()
    }

    @discardableResult
    private func discardAgentRuntimeState(_ runtimeState: DetachedAgentRuntimeState?) -> Bool {
        guard let runtimeState else { return false }
        var didChange = false
        for key in runtimeState.agentPIDKeys {
            if clearAgentPID(key: key, panelId: runtimeState.panelId, clearStatus: true, refreshPorts: false) {
                didChange = true
            }
        }
        if didChange {
            refreshTrackedAgentPorts()
        }
        return didChange
    }

    func adoptDetachedAgentRuntimeState(_ runtimeState: DetachedAgentRuntimeState?) {
        guard let runtimeState else { return }
        for (statusKey, statusEntry) in runtimeState.statusEntries {
            statusEntries[statusKey] = statusEntry
        }
        var didAdoptAgentPID = false
        for (key, pid) in runtimeState.agentPIDs {
            recordAgentPID(key: key, pid: pid, panelId: runtimeState.panelId, refreshPorts: false)
            didAdoptAgentPID = true
        }
        for key in runtimeState.agentPIDKeys where runtimeState.agentPIDs[key] == nil {
            recordAgentPIDOwnership(key: key, panelId: runtimeState.panelId)
        }
        if didAdoptAgentPID {
            refreshTrackedAgentPorts()
        }
    }

    /// Discard every Workspace-owned contribution for a surface whose tab,
    /// pane, or workspace has already been accepted for closure.
    @discardableResult
    func discardClosedPanelLifecycleState(
        panelId: UUID,
        tabId: TabID? = nil,
        paneId: PaneID?,
        panel: (any Panel)?,
        origin: String,
        closePanel: Bool,
        publishSurfaceClosedEvent: Bool,
        clearSurfaceNotifications: Bool,
        requestTransferredRemoteCleanup: Bool,
        cleanupControllerSurfaceState: Bool = false
    ) -> WorkspaceRemoteConfiguration? {
        if publishSurfaceClosedEvent {
            publishCmuxSurfaceClosed(panelId, paneId: paneId, panel: panel, origin: origin)
        }

        let closedAgentRuntimeState = agentRuntimeState(forPanelId: panelId)
        removePendingTerminalInputObservers(forPanelId: panelId)
        let transferredRemoteCleanupConfiguration = transferredRemoteCleanupConfigurationsByPanelId.removeValue(forKey: panelId)
        panelSubscriptions.removeValue(forKey: panelId)?.cancel()
        discardAgentSessionPanelSubscription(panelId: panelId, panel: panel)
        removeBrowserOpenTabSuggestionIfNeeded(panel: panel, panelId: panelId)
        if cleanupControllerSurfaceState {
            TerminalController.shared.cleanupSurfaceState(surfaceIds: [panelId, tabId?.uuid].compactMap { $0 })
        }
        if closePanel {
            panel?.close()
        }

        panels.removeValue(forKey: panelId)
        untrackRemoteTerminalSurface(panelId)
        pendingRemoteTerminalChildExitSurfaceIds.remove(panelId)
        if let tabId {
            surfaceIdToPanelId.removeValue(forKey: tabId)
        } else {
            surfaceIdToPanelId = surfaceIdToPanelId.filter { $0.value != panelId }
        }

        panelDirectories.removeValue(forKey: panelId)
        panelGitBranches.removeValue(forKey: panelId)
        panelPullRequests.removeValue(forKey: panelId)
        panelTitles.removeValue(forKey: panelId)
        panelCustomTitles.removeValue(forKey: panelId)
        pinnedPanelIds.remove(panelId)
        manualUnreadPanelIds.remove(panelId)
        manualUnreadMarkedAt.removeValue(forKey: panelId)
        panelShellActivityStates.removeValue(forKey: panelId)
        clearAgentLifecycleStates(panelId: panelId)
        surfaceTTYNames.removeValue(forKey: panelId)
        discardRemotePTYSessionID(panelId: panelId)
        surfaceResumeBindingsByPanelId.removeValue(forKey: panelId)
        surfaceListeningPorts.removeValue(forKey: panelId)
        restoredTerminalScrollbackByPanelId.removeValue(forKey: panelId)
#if DEBUG
        debugSessionSnapshotScrollbackFallbackPanelIds.remove(panelId)
        debugSessionSnapshotSyntheticScrollbackByPanelId.removeValue(forKey: panelId)
#endif
        discardAgentRuntimeState(closedAgentRuntimeState)
        restoredAgentSnapshotsByPanelId.removeValue(forKey: panelId)
        restoredAgentResumeStatesByPanelId.removeValue(forKey: panelId)
        invalidatedRestoredAgentFingerprintsByPanelId.removeValue(forKey: panelId)
        PortScanner.shared.unregisterPanel(workspaceId: id, panelId: panelId)
        terminalInheritanceFontPointsByPanelId.removeValue(forKey: panelId)
        if lastTerminalConfigInheritancePanelId == panelId {
            lastTerminalConfigInheritancePanelId = nil
        }
        if clearSurfaceNotifications {
            AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: id, surfaceId: panelId)
        }

        if requestTransferredRemoteCleanup, let transferredRemoteCleanupConfiguration {
            Self.requestSSHControlMasterCleanupIfNeeded(configuration: transferredRemoteCleanupConfiguration)
        }
        return transferredRemoteCleanupConfiguration
    }
}
