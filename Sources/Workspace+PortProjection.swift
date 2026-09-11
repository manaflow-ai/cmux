import Foundation

// Port observations and sidebar projection stay together so Workspace keeps
// authoritative raw ports while exposing a filtered presentation projection.
extension Workspace {
    func recomputeListeningPorts() {
        let policy = currentSidebarPortVisibilityPolicy()
        let unique = Set(surfaceListeningPorts.values.flatMap { $0 })
            .union(agentListeningPorts)
            .union(remoteDetectedPorts)
            .union(remoteForwardedPorts)
        let authoritativePorts = unique.sorted()
        if listeningPorts != authoritativePorts {
            listeningPorts = authoritativePorts
        }
        // Keep authoritative observations independent from the sidebar
        // projection so control APIs and automation never lose hidden badges.
        setSidebarVisibleListeningPorts(policy.visiblePorts(from: authoritativePorts))
    }

    /// Returns the indexed sidebar projection policy shared by every port-badge surface.
    func currentSidebarPortVisibilityPolicy() -> SidebarPortVisibilityPolicy {
        sidebarPortVisibilityPolicy
    }

    /// Applies one or more raw per-surface observations with a single publication.
    /// The sidebar cache is updated only for the touched surfaces before observers
    /// receive the new authoritative dictionary.
    func updateSurfaceListeningPorts(
        setting updates: [UUID: [Int]] = [:],
        removing removedPanelIds: Set<UUID> = []
    ) {
        guard !updates.isEmpty || !removedPanelIds.isEmpty else { return }

        var next = surfaceListeningPorts
        var didChange = false

        for panelId in removedPanelIds {
            if next.removeValue(forKey: panelId) != nil {
                didChange = true
            }
            sidebarVisibleSurfacePorts.removeValue(forKey: panelId)
        }

        for (panelId, ports) in updates {
            let visiblePorts = sidebarPortVisibilityPolicy.visiblePorts(from: ports)
            if sidebarVisibleSurfacePorts[panelId] != visiblePorts {
                sidebarVisibleSurfacePorts[panelId] = visiblePorts
            }
            if next[panelId] != ports {
                next[panelId] = ports
                didChange = true
            }
        }

        guard didChange else { return }
        surfaceListeningPorts = next
    }

    func setSurfaceListeningPorts(_ ports: [Int], for panelId: UUID) {
        updateSurfaceListeningPorts(setting: [panelId: ports])
    }

    func removeSurfaceListeningPorts(for panelId: UUID) {
        updateSurfaceListeningPorts(removing: [panelId])
    }

    func removeAllSurfaceListeningPorts() {
        sidebarVisibleSurfacePorts.removeAll()
        guard !surfaceListeningPorts.isEmpty else { return }
        surfaceListeningPorts.removeAll()
    }

    func retainSurfaceListeningPorts(for validPanelIds: Set<UUID>) {
        let removedPanelIds = Set(surfaceListeningPorts.keys).subtracting(validPanelIds)
        updateSurfaceListeningPorts(removing: removedPanelIds)
    }

    func setSidebarVisibleListeningPorts(_ ports: [Int]) {
        guard sidebarVisibleListeningPorts != ports else { return }
        sidebarVisibleListeningPorts = ports
    }

    /// Rebuilds the per-surface sidebar projection outside SwiftUI render paths.
    func refreshSidebarVisibleSurfacePorts(using policy: SidebarPortVisibilityPolicy) {
        let next = surfaceListeningPorts.mapValues { policy.visiblePorts(from: $0) }
        guard next != sidebarVisibleSurfacePorts else { return }
        sidebarVisibleSurfacePorts = next
    }

    /// Returns the cached sidebar projection for one surface.
    func sidebarVisiblePorts(for panelId: UUID) -> [Int] {
        sidebarVisibleSurfacePorts[panelId] ?? []
    }

    /// Rebuilds and applies the policy only when ignored-port behavior changes.
    func refreshSidebarPortVisibilityPolicy() {
        let nextPolicy = SidebarPortVisibilityPolicy(
            ignoredRules: settings.value(for: SettingCatalog().sidebar.ignoredPorts)
        )
        guard nextPolicy != sidebarPortVisibilityPolicy else { return }
        sidebarPortVisibilityPolicy = nextPolicy
        refreshSidebarVisibleSurfacePorts(using: nextPolicy)
        recomputeListeningPorts()
    }

    /// Whether remote listening-port discovery may run, derived from the global
    /// sidebar ports-visibility settings. Mirrors the sidebar's own precedence
    /// (`sidebar.hideAllDetails` wins over `sidebar.showPorts`, see
    /// `SidebarWorkspaceAuxiliaryDetailVisibility.resolved`): when the ports
    /// detail is not displayed there is nothing for the remote scans to
    /// populate, so the backend ssh port-scan loop is suspended (issue #6123).
    static func remotePortScanningEnabledFromSettings(defaults: UserDefaults = .standard) -> Bool {
        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let catalog = SettingCatalog()
        let showsPorts = settings.value(for: catalog.sidebar.showPorts)
        let hidesAllDetails = settings.value(for: catalog.sidebar.hideAllDetails)
        return showsPorts && !hidesAllDetails
    }

    /// Pushes the current remote port-scanning enablement to this workspace's
    /// active remote session, if any. No-op for non-remote workspaces.
    func applyRemotePortScanningEnabled(_ enabled: Bool) {
        remoteSessionController?.updateRemotePortScanningEnabled(enabled)
    }

    func listRemotePTYSessions() throws -> [[String: Any]] {
        guard let controller = remoteSessionController else {
            throw NSError(domain: "cmux.remote.pty", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "remote connection is not active",
            ])
        }
        return try controller.listPTYSessions()
    }

    func closeRemotePTYSession(sessionID: String) throws {
        guard let controller = remoteSessionController else {
            throw NSError(domain: "cmux.remote.pty", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "remote connection is not active",
            ])
        }
        try controller.closePTYSession(sessionID: sessionID)
    }

    func resizeRemotePTY(sessionID: String, attachmentID: String, attachmentToken: String, cols: Int, rows: Int) throws {
        guard let controller = remoteSessionController else {
            throw NSError(domain: "cmux.remote.pty", code: 13, userInfo: [
                NSLocalizedDescriptionKey: "remote connection is not active",
            ])
        }
        try controller.resizePTY(
            sessionID: sessionID,
            attachmentID: attachmentID,
            attachmentToken: attachmentToken,
            cols: cols,
            rows: rows
        )
    }

    func detachRemotePTYAttachment(sessionID: String, attachmentID: String, attachmentToken: String) throws {
        guard let controller = remoteSessionController else {
            throw NSError(domain: "cmux.remote.pty", code: 14, userInfo: [
                NSLocalizedDescriptionKey: "remote connection is not active",
            ])
        }
        try controller.detachPTYSession(
            sessionID: sessionID,
            attachmentID: attachmentID,
            attachmentToken: attachmentToken
        )
    }
}
