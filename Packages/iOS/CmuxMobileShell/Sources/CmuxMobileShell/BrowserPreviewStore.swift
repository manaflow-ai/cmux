import CMUXMobileCore
import Foundation

/// Per-surface browser-frame fan-out. Unregistered surfaces retain no bitmap.
@MainActor
final class BrowserPreviewStore {
    private var statesBySurfaceID: [String: BrowserPreviewSurfaceState] = [:]
    private(set) var isConsumptionActive = true

    var registeredSurfaceIDs: Set<String> { Set(statesBySurfaceID.keys) }

    var demand: MobileBrowserPreviewDemand {
        guard isConsumptionActive else { return MobileBrowserPreviewDemand(isActive: false) }
        let full = Set(statesBySurfaceID.compactMap { id, state in
            state.requestedResolution == .full ? id : nil
        })
        return MobileBrowserPreviewDemand(
            isActive: true,
            previewSurfaceIDs: registeredSurfaceIDs.subtracting(full),
            fullSurfaceIDs: full
        )
    }

    func updates(
        surfaceID: String,
        resolution: MobileBrowserPreviewResolution,
        onDemandChanged: @escaping @MainActor @Sendable () -> Void
    ) -> AsyncStream<MobileBrowserPreviewFrame> {
        let token = UUID()
        let state = statesBySurfaceID[surfaceID] ?? BrowserPreviewSurfaceState()
        let previousResolution = state.requestedResolution
        statesBySurfaceID[surfaceID] = state
        state.resolutions[token] = resolution
        let demandChanged = state.continuations.isEmpty || previousResolution != state.requestedResolution
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            state.continuations[token] = continuation
            // A cached card-size frame is meaningful first-frame content for a
            // full-screen consumer while the Mac renders the requested full frame.
            if let latestFrame = state.latestFrame {
                continuation.yield(latestFrame)
            }
            if demandChanged { onDemandChanged() }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    guard let self,
                          let state = self.statesBySurfaceID[surfaceID] else { return }
                    let previousResolution = state.requestedResolution
                    state.continuations.removeValue(forKey: token)
                    state.resolutions.removeValue(forKey: token)
                    if state.continuations.isEmpty {
                        self.statesBySurfaceID.removeValue(forKey: surfaceID)
                        onDemandChanged()
                    } else if previousResolution != state.requestedResolution {
                        onDemandChanged()
                    }
                }
            }
        }
    }

    func receive(_ frame: MobileBrowserPreviewFrame) {
        guard isConsumptionActive,
              let state = statesBySurfaceID[frame.surfaceID] else { return }
        state.latestFrame = frame
        for (token, continuation) in state.continuations {
            guard frame.resolution == .full || state.resolutions[token] == .preview else { continue }
            continuation.yield(frame)
        }
    }

    func setConsumptionActive(_ isActive: Bool) {
        guard isConsumptionActive != isActive else { return }
        isConsumptionActive = isActive
        if !isActive {
            for state in statesBySurfaceID.values { state.latestFrame = nil }
        }
    }

    func resetForReconnect() {
        for state in statesBySurfaceID.values { state.latestFrame = nil }
    }
}
