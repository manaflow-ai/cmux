import CMUXMobileCore
import CmuxAuthRuntime
import Foundation

/// Demand-gated, cadence-limited Mac browser snapshot emitter.
@MainActor
final class MobileBrowserPreviewObserver {
    typealias Snapshot = @MainActor (String, MobileBrowserPreviewResolution, UInt64) async -> MobileBrowserPreviewFrame?
    typealias Emit = @MainActor (MobileBrowserPreviewFrame) -> Void
    typealias Now = @MainActor () -> TimeInterval
    typealias Delay = @MainActor (Duration) async throws -> Void

    private let minimumInterval: TimeInterval
    private let snapshot: Snapshot
    private let emit: Emit
    private let now: Now
    private let delay: Delay
    private var demandByConnectionID: [UUID: MobileBrowserPreviewDemandSummary] = [:]
    private var lastEmissionBySurfaceID: [String: TimeInterval] = [:]
    private var sequenceBySurfaceID: [String: UInt64] = [:]
    private var dirtySurfaceIDs = Set<String>()
    private var workBySurfaceID: [String: Task<Void, Never>] = [:]
    private var workGenerationBySurfaceID: [String: UUID] = [:]

    /// Creates a browser preview emitter with injectable capture and time seams.
    init(
        minimumInterval: TimeInterval = 1,
        snapshot: @escaping Snapshot,
        emit: @escaping Emit,
        now: @escaping Now = { Date().timeIntervalSinceReferenceDate },
        delay: @escaping Delay = { duration in
            // Intentional bounded browser-preview cadence delay; demand removal cancels it.
            try await ContinuousClock().sleep(for: duration)
        }
    ) {
        self.minimumInterval = max(1, minimumInterval)
        self.snapshot = snapshot
        self.emit = emit
        self.now = now
        self.delay = delay
    }

    /// Replaces one connection's aggregate browser demand.
    func replaceConnectionDemand(
        connectionID: UUID,
        summary: MobileBrowserPreviewDemandSummary
    ) {
        let previous = effectiveDemand
        if summary.hasDemand {
            demandByConnectionID[connectionID] = summary
        } else {
            demandByConnectionID.removeValue(forKey: connectionID)
        }
        let next = effectiveDemand

        for surfaceID in previous.surfaceIDs.subtracting(next.surfaceIDs) {
            cancelSurface(surfaceID)
        }
        for surfaceID in next.surfaceIDs where previous.resolution(for: surfaceID) != next.resolution(for: surfaceID) {
            workBySurfaceID.removeValue(forKey: surfaceID)?.cancel()
            workGenerationBySurfaceID.removeValue(forKey: surfaceID)
            dirtySurfaceIDs.insert(surfaceID)
            schedule(surfaceID: surfaceID)
        }
    }

    /// Marks navigation, title, progress, or content state as needing a new frame.
    func noteContentChanged(surfaceID: String) {
        guard effectiveDemand.resolution(for: surfaceID) != nil else { return }
        dirtySurfaceIDs.insert(surfaceID)
        schedule(surfaceID: surfaceID)
    }

    /// Releases every demand and pending capture.
    func stop() {
        for task in workBySurfaceID.values { task.cancel() }
        workBySurfaceID.removeAll()
        workGenerationBySurfaceID.removeAll()
        demandByConnectionID.removeAll()
        dirtySurfaceIDs.removeAll()
        lastEmissionBySurfaceID.removeAll()
        sequenceBySurfaceID.removeAll()
    }

    private var effectiveDemand: MobileBrowserPreviewDemandSummary {
        MobileBrowserPreviewDemandSummary(demands: demandByConnectionID.values.map {
            MobileBrowserPreviewDemand(
                previewSurfaceIDs: $0.previewSurfaceIDs,
                fullSurfaceIDs: $0.fullSurfaceIDs
            )
        })
    }

    private func schedule(surfaceID: String) {
        guard workBySurfaceID[surfaceID] == nil,
              dirtySurfaceIDs.contains(surfaceID),
              effectiveDemand.resolution(for: surfaceID) != nil else { return }
        let remaining = max(
            0,
            minimumInterval - (now() - (lastEmissionBySurfaceID[surfaceID] ?? -Double.infinity))
        )
        let generation = UUID()
        workGenerationBySurfaceID[surfaceID] = generation
        workBySurfaceID[surfaceID] = Task { @MainActor [weak self] in
            guard let self else { return }
            if remaining > 0 {
                do {
                    try await self.delay(.seconds(remaining))
                } catch {
                    _ = self.finishWork(surfaceID: surfaceID, generation: generation)
                    return
                }
            }
            guard self.workGenerationBySurfaceID[surfaceID] == generation,
                  !Task.isCancelled,
                  let resolution = self.effectiveDemand.resolution(for: surfaceID) else {
                _ = self.finishWork(surfaceID: surfaceID, generation: generation)
                return
            }
            self.dirtySurfaceIDs.remove(surfaceID)
            let sequence = (self.sequenceBySurfaceID[surfaceID] ?? 0) &+ 1
            let frame = await self.snapshot(surfaceID, resolution, sequence)
            guard self.finishWork(surfaceID: surfaceID, generation: generation) else { return }
            guard !Task.isCancelled,
                  self.effectiveDemand.resolution(for: surfaceID) == resolution,
                  let frame else {
                if self.dirtySurfaceIDs.contains(surfaceID) { self.schedule(surfaceID: surfaceID) }
                return
            }
            self.sequenceBySurfaceID[surfaceID] = sequence
            self.lastEmissionBySurfaceID[surfaceID] = self.now()
            self.emit(frame)
            if self.dirtySurfaceIDs.contains(surfaceID) { self.schedule(surfaceID: surfaceID) }
        }
    }

    private func cancelSurface(_ surfaceID: String) {
        workBySurfaceID.removeValue(forKey: surfaceID)?.cancel()
        workGenerationBySurfaceID.removeValue(forKey: surfaceID)
        dirtySurfaceIDs.remove(surfaceID)
        lastEmissionBySurfaceID.removeValue(forKey: surfaceID)
        sequenceBySurfaceID.removeValue(forKey: surfaceID)
    }

    @discardableResult
    private func finishWork(surfaceID: String, generation: UUID) -> Bool {
        guard workGenerationBySurfaceID[surfaceID] == generation else { return false }
        workGenerationBySurfaceID.removeValue(forKey: surfaceID)
        workBySurfaceID.removeValue(forKey: surfaceID)
        return true
    }

    #if DEBUG
    var debugDemandForTesting: MobileBrowserPreviewDemandSummary { effectiveDemand }

    func debugAwaitWorkForTesting(surfaceID: String) async {
        await workBySurfaceID[surfaceID]?.value
    }
    #endif
}

/// Composition-owned bridge between connection demand and the snapshot emitter.
@MainActor
final class MobileBrowserPreviewCoordinator {
    static let shared = MobileBrowserPreviewCoordinator()

    private var observer: MobileBrowserPreviewObserver?

    private init() {}

    func configure(observer: MobileBrowserPreviewObserver) {
        self.observer?.stop()
        self.observer = observer
    }

    func replaceConnectionDemand(
        connectionID: UUID,
        summary: MobileBrowserPreviewDemandSummary
    ) {
        observer?.replaceConnectionDemand(connectionID: connectionID, summary: summary)
    }

    func noteContentChanged(surfaceID: String) {
        observer?.noteContentChanged(surfaceID: surfaceID)
    }

    func stop() {
        observer?.stop()
    }
}

/// Per-connection aggregation kept outside the already-large host service file.
struct MobileBrowserPreviewConnectionDemand {
    private var demandsByStreamID: [String: MobileBrowserPreviewDemand] = [:]

    var summary: MobileBrowserPreviewDemandSummary {
        MobileBrowserPreviewDemandSummary(demands: demandsByStreamID.values)
    }

    mutating func replace(
        streamID: String,
        topics: Set<String>,
        demand: MobileBrowserPreviewDemand?
    ) {
        if topics.contains("browser.preview"), let demand {
            demandsByStreamID[streamID] = demand
        } else {
            demandsByStreamID.removeValue(forKey: streamID)
        }
    }

    mutating func remove(streamID: String) {
        demandsByStreamID.removeValue(forKey: streamID)
    }

    mutating func removeAll() {
        demandsByStreamID.removeAll()
    }

    func accepts(surfaceID: String) -> Bool {
        summary.resolution(for: surfaceID) != nil
    }

    func publish(connectionID: UUID) {
        let summary = summary
        Task { @MainActor in
            MobileBrowserPreviewCoordinator.shared.replaceConnectionDemand(
                connectionID: connectionID,
                summary: summary
            )
        }
    }
}

extension AppDelegate {
    func configureMobileHost(auth: AuthCoordinator, tabManager: TabManager) {
        MobileHostService.shared.configure(auth: auth)
        let observer = MobileBrowserPreviewObserver(
            snapshot: { [weak tabManager] surfaceID, resolution, sequence in
                guard let surfaceUUID = UUID(uuidString: surfaceID),
                      let panel = tabManager?.tabs.lazy
                          .compactMap({ $0.panels[surfaceUUID] as? BrowserPanel })
                          .first else { return nil }
                return await panel.mobileBrowserPreviewFrame(
                    resolution: resolution,
                    sequence: sequence
                )
            },
            emit: { frame in
                guard let payload = try? frame.jsonObject() else { return }
                MobileHostService.emitEvent(topic: "browser.preview", payload: payload)
                #if DEBUG
                cmuxDebugLog(
                    "mobile.browser_preview surface=\(frame.surfaceID.prefix(8)) " +
                        "resolution=\(frame.resolution.rawValue) bytes=\(frame.imageData.count) " +
                        "seq=\(frame.sequence)"
                )
                #endif
            }
        )
        MobileBrowserPreviewCoordinator.shared.configure(observer: observer)
    }
}
