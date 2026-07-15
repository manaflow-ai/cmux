import CMUXMobileCore
import CmuxMobileDiagnostics
import CmuxMobileRPC
import Foundation

extension MobileShellComposite {
    /// Default preview publication cap: four updates per second per surface.
    public static let defaultPreviewGridUpdatesPerSecond = 4.0
    static let renderGridDemandCapability = "terminal.render_grid.demand.v1"

    /// Opens an independently throttled preview stream for one visible surface.
    ///
    /// Cancelling iteration unregisters the surface, clears its accumulated grid,
    /// and updates Mac-side demand. Registering it again starts in the skeleton
    /// state and requests a new authoritative full frame.
    /// - Parameter surfaceID: The terminal surface to preview.
    /// - Returns: An immutable snapshot stream scoped to only that surface.
    public func previewGridUpdates(surfaceID: String) -> AsyncStream<PreviewGridSnapshot> {
        let wasRegistered = previewGridSessionState.store.registeredSurfaceIDs.contains(surfaceID)
        let stream = previewGridSessionState.store.updates(surfaceID: surfaceID) { [weak self] in
            self?.previewGridRegistrationEnded(surfaceID: surfaceID)
        }
        if !wasRegistered {
            scheduleRenderGridDemandRefresh()
            requestPreviewGridBaseline(surfaceID: surfaceID)
        }
        return stream
    }

    func terminalEventSubscriptionParameters(topics: [String]) -> [String: Any] {
        var params: [String: Any] = [
            "stream_id": terminalEventStreamID,
            "topics": topics,
        ]
        if supportedHostCapabilities.contains(Self.renderGridDemandCapability) {
            params["render_grid_demand"] = currentRenderGridDemand.jsonObject()
        }
        if Self.hostSupportsBrowserPreview(supportedHostCapabilities) {
            params["browser_preview_demand"] = currentBrowserPreviewDemand.jsonObject()
        }
        return params
    }

    func routeIncomingRenderGrid(_ frame: MobileTerminalRenderGridFrame) {
        if previewGridSessionState.store.receive(frame) {
            requestPreviewGridBaseline(surfaceID: frame.surfaceID)
        }
        guard hasTerminalOutputSink(surfaceID: frame.surfaceID) else { return }
        #if DEBUG
        MobileDebugLog.anchormux(
            "sync.render_grid_fanout surface=\(frame.surfaceID) preview=\(previewGridSessionState.store.registeredSurfaceIDs.contains(frame.surfaceID)) mounted=true seq=\(frame.stateSeq)"
        )
        #endif
        deliverAuthoritativeTerminalRenderGrid(frame, source: "event")
    }

    func scheduleRenderGridDemandRefresh() {
        previewGridSessionState.demandRevision &+= 1
        guard supportedHostCapabilities.contains(Self.renderGridDemandCapability),
              remoteClient != nil,
              connectionState == .connected,
              previewGridSessionState.demandRefreshTask == nil else { return }
        previewGridSessionState.demandRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let revision = self.previewGridSessionState.demandRevision
                guard let client = self.remoteClient,
                      self.connectionState == .connected else { break }
                _ = await self.requestTerminalEventSubscription(
                    client: client,
                    reason: "render_grid_demand",
                    topics: self.mobileEventTopics(for: self.terminalOutputTransport)
                )
                guard revision != self.previewGridSessionState.demandRevision else { break }
            }
            self.previewGridSessionState.demandRefreshTask = nil
        }
    }

    func requestPreviewGridBaselines() {
        guard previewGridSessionState.store.isConsumptionActive else { return }
        for surfaceID in previewGridSessionState.store.registeredSurfaceIDs {
            requestPreviewGridBaseline(surfaceID: surfaceID)
        }
    }

    func previewGridConnectionDidChange() {
        previewGridSessionState.cancelConnectionTasks()
        previewGridSessionState.store.resetForReconnect()
        scheduleRenderGridDemandRefresh()
        browserPreviewConnectionDidChange()
    }

    func previewGridDidSuspendForeground() {
        previewGridSessionState.store.setConsumptionActive(false)
        previewGridSessionState.cancelConnectionTasks()
        scheduleRenderGridDemandRefresh()
        browserPreviewDidSuspendForeground()
    }

    func previewGridDidResumeForeground() {
        previewGridSessionState.store.setConsumptionActive(true)
        scheduleRenderGridDemandRefresh()
        requestPreviewGridBaselines()
        browserPreviewDidResumeForeground()
    }

    private var currentRenderGridDemand: MobileRenderGridDemand {
        let isActive = previewGridSessionState.store.isConsumptionActive
        let focused = isActive ? Set(terminalByteContinuationsBySurfaceID.keys) : []
        let previews = isActive
            ? previewGridSessionState.store.registeredSurfaceIDs.subtracting(focused)
            : []
        return MobileRenderGridDemand(
            isActive: isActive,
            focusedSurfaceIDs: focused,
            previewSurfaceIDs: previews
        )
    }

    private func previewGridRegistrationEnded(surfaceID: String) {
        previewGridSessionState.baselineTasksBySurfaceID.removeValue(forKey: surfaceID)?.cancel()
        scheduleRenderGridDemandRefresh()
    }

    private func requestPreviewGridBaseline(surfaceID: String) {
        guard previewGridSessionState.store.isConsumptionActive,
              previewGridSessionState.store.registeredSurfaceIDs.contains(surfaceID),
              previewGridSessionState.baselineTasksBySurfaceID[surfaceID] == nil,
              let client = remoteClient,
              connectionState == .connected,
              let workspaceID = workspaceID(forTerminalID: surfaceID) else { return }
        let generation = connectionGeneration
        let task = Task { @MainActor [weak self] in
            defer { self?.previewGridSessionState.baselineTasksBySurfaceID[surfaceID] = nil }
            guard let self else { return }
            do {
                let request = try MobileCoreRPCClient.requestData(
                    method: "mobile.terminal.replay",
                    params: [
                        "workspace_id": self.remoteWorkspaceID(for: workspaceID).rawValue,
                        "surface_id": surfaceID,
                    ]
                )
                let data = try await client.sendRequest(request)
                guard self.remoteClient === client,
                      self.connectionGeneration == generation,
                      self.previewGridSessionState.store.registeredSurfaceIDs.contains(surfaceID),
                      let response = try? MobileTerminalReplayResponse.decode(data),
                      let frame = response.renderGrid else { return }
                _ = self.previewGridSessionState.store.receive(frame)
            } catch {
                // A later live delta asks for another baseline; cancellation and
                // disconnect intentionally stay silent here.
            }
        }
        previewGridSessionState.baselineTasksBySurfaceID[surfaceID] = task
    }
}
