public import CMUXMobileCore
internal import CmuxMobileRPC
import Foundation

extension MobileShellComposite {
    static let browserPreviewCapability = "browser.preview.v1"

    static func hostSupportsBrowserPreview(_ capabilities: Set<String>) -> Bool {
        capabilities.contains(browserPreviewCapability)
    }

    /// Opens a demand-scoped bitmap stream for one mirrored Mac browser surface.
    public func browserPreviewUpdates(
        surfaceID: String,
        resolution: MobileBrowserPreviewResolution = .preview
    ) -> AsyncStream<MobileBrowserPreviewFrame> {
        previewGridSessionState.browserPreview.store.updates(
            surfaceID: surfaceID,
            resolution: resolution
        ) { [weak self] in
            self?.scheduleBrowserPreviewDemandRefresh()
        }
    }

    func routeIncomingBrowserPreview(_ event: MobileEventEnvelope) {
        guard let payload = event.payloadJSON,
              let frame = try? JSONDecoder().decode(MobileBrowserPreviewFrame.self, from: payload) else {
            return
        }
        previewGridSessionState.browserPreview.store.receive(frame)
    }

    func scheduleBrowserPreviewDemandRefresh() {
        let session = previewGridSessionState.browserPreview
        session.demandRevision &+= 1
        guard Self.hostSupportsBrowserPreview(supportedHostCapabilities),
              remoteClient != nil,
              connectionState == .connected,
              session.demandRefreshTask == nil else { return }
        session.demandRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let revision = session.demandRevision
                guard let client = self.remoteClient,
                      self.connectionState == .connected else { break }
                _ = await self.requestTerminalEventSubscription(
                    client: client,
                    reason: "browser_preview_demand",
                    topics: self.mobileEventTopics(for: self.terminalOutputTransport)
                )
                guard revision != session.demandRevision else { break }
            }
            session.demandRefreshTask = nil
        }
    }

    func browserPreviewConnectionDidChange() {
        let session = previewGridSessionState.browserPreview
        session.cancelConnectionTasks()
        session.store.resetForReconnect()
        scheduleBrowserPreviewDemandRefresh()
    }

    func browserPreviewDidSuspendForeground() {
        let session = previewGridSessionState.browserPreview
        session.store.setConsumptionActive(false)
        session.cancelConnectionTasks()
        scheduleBrowserPreviewDemandRefresh()
    }

    func browserPreviewDidResumeForeground() {
        previewGridSessionState.browserPreview.store.setConsumptionActive(true)
        scheduleBrowserPreviewDemandRefresh()
    }

    var currentBrowserPreviewDemand: MobileBrowserPreviewDemand {
        previewGridSessionState.browserPreview.store.demand
    }
}
