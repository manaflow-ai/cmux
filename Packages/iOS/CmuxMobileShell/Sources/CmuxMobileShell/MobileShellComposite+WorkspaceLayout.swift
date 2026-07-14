public import CMUXMobileCore
import CmuxMobileRPC
public import CmuxMobileShellModel
import Foundation

extension MobileShellComposite {
    static let workspaceLayoutCapability = "workspace.layout.v1"

    static func hostSupportsWorkspaceLayout(_ capabilities: Set<String>) -> Bool {
        capabilities.contains(workspaceLayoutCapability)
    }

    func mobileEventTopics(for transport: TerminalOutputTransport) -> [String] {
        var topics = transport.eventTopics
        if Self.hostSupportsWorkspaceLayout(supportedHostCapabilities) {
            topics.insert("workspace.layout.updated", at: 1)
        }
        if Self.hostSupportsBrowserPreview(supportedHostCapabilities) {
            topics.insert("browser.preview", at: min(2, topics.count))
        }
        return topics
    }

    /// Enables one secondary connection's event topics on the Mac host.
    func enableSecondaryEventSubscription(
        on client: MobileCoreRPCClient,
        streamID: String,
        topics: Set<String>
    ) async {
        guard let request = try? MobileCoreRPCClient.requestData(
            method: "mobile.events.subscribe",
            params: ["stream_id": streamID, "topics": topics.sorted()]
        ) else { return }
        _ = try? await client.sendRequest(request)
    }

    /// Returns whether the row's owning Mac advertised pane-layout snapshots.
    /// - Parameter workspaceID: A workspace row id from the aggregated list.
    /// - Returns: `true` only for the specific Mac that owns the row.
    public func supportsWorkspaceLayout(
        for workspaceID: MobileWorkspacePreview.ID
    ) -> Bool {
        workspaces.first(where: { $0.id == workspaceID })?.supportsWorkspaceLayout == true
    }

    /// Returns the latest authoritative layout for a workspace row.
    /// - Parameter workspaceID: A workspace row id from the aggregated list.
    /// - Returns: The latest layout snapshot, or `nil` before the first RPC/push arrives.
    public func workspaceLayout(
        for workspaceID: MobileWorkspacePreview.ID
    ) -> MobileWorkspaceLayout? {
        guard let identity = workspaceLayoutIdentity(for: workspaceID) else { return nil }
        return workspaceLayoutsByMacDeviceID[identity.macDeviceID]?[identity.remoteWorkspaceID]
    }

    /// The latest layout for the selected workspace.
    public var selectedWorkspaceLayout: MobileWorkspaceLayout? {
        selectedWorkspaceID.flatMap { workspaceLayout(for: $0) }
    }

    /// Fetches and applies the authoritative layout for one workspace.
    /// - Parameter workspaceID: The aggregated workspace row id to refresh.
    public func refreshWorkspaceLayout(for workspaceID: MobileWorkspacePreview.ID) async {
        guard supportsWorkspaceLayout(for: workspaceID),
              let identity = workspaceLayoutIdentity(for: workspaceID) else {
            return
        }
        let target = workspaceMutationTarget(for: workspaceID)
        guard let client = target.client else { return }
        do {
            let layout = try await client.workspaceLayout(
                workspaceID: identity.remoteWorkspaceID
            )
            let currentTarget = workspaceMutationTarget(for: workspaceID)
            guard currentTarget.client === client else { return }
            applyWorkspaceLayout(layout, macDeviceID: identity.macDeviceID)
        } catch {
            // The capability gate keeps older Macs on the flat-terminal fallback.
            // Preserve the last good layout if a capable Mac has a transient error.
        }
    }

    func handleWorkspaceLayoutUpdatedEvent(
        _ event: MobileEventEnvelope,
        macDeviceID: String? = nil
    ) {
        let ownerID = macDeviceID ?? foregroundMacKey
        guard let payload = event.payloadJSON,
              let layout = try? JSONDecoder().decode(MobileWorkspaceLayout.self, from: payload),
              let rowID = workspaceRowID(
                  remoteWorkspaceID: layout.workspaceID,
                  macDeviceID: ownerID
              ),
              supportsWorkspaceLayout(for: rowID) else {
            return
        }
        applyWorkspaceLayout(layout, macDeviceID: ownerID)
    }

    func applyWorkspaceLayout(_ layout: MobileWorkspaceLayout, macDeviceID: String) {
        workspaceLayoutsByMacDeviceID[macDeviceID, default: [:]][layout.workspaceID] = layout
    }

    func pruneWorkspaceLayouts(
        forMacDeviceID macDeviceID: String,
        keepingRemoteWorkspaceIDs workspaceIDs: Set<String>
    ) {
        guard let layouts = workspaceLayoutsByMacDeviceID[macDeviceID] else { return }
        let retained = layouts.filter {
            workspaceIDs.contains($0.key)
        }
        workspaceLayoutsByMacDeviceID[macDeviceID] = retained.isEmpty ? nil : retained
    }

    private func workspaceLayoutIdentity(
        for workspaceID: MobileWorkspacePreview.ID
    ) -> (macDeviceID: String, remoteWorkspaceID: String)? {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else {
            return nil
        }
        let ownerID = workspace.macDeviceID ?? foregroundMacKey
        return (ownerID, workspace.rpcWorkspaceID.rawValue)
    }

    private func workspaceRowID(
        remoteWorkspaceID: String,
        macDeviceID: String
    ) -> MobileWorkspacePreview.ID? {
        workspaces.first(where: { workspace in
            workspace.rpcWorkspaceID.rawValue == remoteWorkspaceID
                && (workspace.macDeviceID ?? foregroundMacKey) == macDeviceID
        })?.id
    }
}

extension MobileShellComposite.TerminalOutputTransport {
    var eventTopics: [String] {
        switch self {
        case .hybrid:
            return ["workspace.updated", "terminal.bytes", "terminal.render_grid", "terminal.set_font", "notification.dismissed", "notification.badge"]
        case .renderGrid:
            return ["workspace.updated", "terminal.render_grid", "terminal.set_font", "notification.dismissed", "notification.badge"]
        case .rawBytes:
            return ["workspace.updated", "terminal.bytes", "terminal.set_font", "notification.dismissed", "notification.badge"]
        }
    }
}
