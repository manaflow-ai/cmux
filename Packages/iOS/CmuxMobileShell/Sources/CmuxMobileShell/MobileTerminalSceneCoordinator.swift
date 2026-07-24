import CMUXMobileCore
import CmuxMobileRPC
import Foundation

/// Owns one full-first semantic-scene lane per mounted terminal surface.
actor MobileTerminalSceneCoordinator {
    struct Configuration: Sendable {
        let request: CmxByteTransportRequest
        let scene: MobileTerminalSceneRequest
        let lifecycleID: UUID
        /// Returns true only when this envelope caused the exact frame to become visible.
        let consume: @Sendable (MobileTerminalSceneEnvelope) async throws -> Bool
        let finished: @Sendable (
            _ token: UUID,
            _ termination: MobileTerminalSceneTermination
        ) async -> Void
    }

    enum InputResult: Equatable, Sendable {
        case unavailable
        case queued
        case sent
        case failed
    }

    private struct Entry {
        let token: UUID
        let configuration: Configuration
        var lane: (any MobileTerminalSceneConnection)?
        var task: Task<Void, Never>?
        var ready = false
        var pendingInputs: [Data] = []
        var pendingInputBytes = 0
    }

    private static let maximumPendingInputBytes = 256 * 1_024
    private static let maximumPendingInputChunks = 256
    private let provider: MobileTerminalSceneProvider
    private var entriesBySurfaceID: [String: Entry] = [:]

    init(provider: @escaping MobileTerminalSceneProvider) {
        self.provider = provider
    }

    func activate(_ configuration: Configuration) async throws -> UUID {
        let surfaceID = configuration.scene.surfaceID
        let token = UUID()
        let previous = entriesBySurfaceID.removeValue(forKey: surfaceID)
        previous?.task?.cancel()
        await previous?.lane?.close()

        entriesBySurfaceID[surfaceID] = Entry(
            token: token,
            configuration: configuration,
            lane: nil,
            task: nil
        )
        do {
            let lane = try await provider(configuration.request, configuration.scene)
            guard var entry = entriesBySurfaceID[surfaceID],
                  entry.token == token else {
                await lane.close()
                throw CancellationError()
            }
            entry.lane = lane
            let task = Task { [weak self] in
                guard let self else { return }
                await self.run(surfaceID: surfaceID, token: token, lane: lane)
            }
            entry.task = task
            entriesBySurfaceID[surfaceID] = entry
            return token
        } catch {
            if entriesBySurfaceID[surfaceID]?.token == token {
                entriesBySurfaceID[surfaceID] = nil
            }
            throw error
        }
    }

    func sendInput(_ input: Data, surfaceID: String) async -> InputResult {
        guard var entry = entriesBySurfaceID[surfaceID],
              let lane = entry.lane else {
            return .unavailable
        }
        guard entry.ready else {
            guard input.count <= Self.maximumPendingInputBytes - entry.pendingInputBytes,
                  entry.pendingInputs.count < Self.maximumPendingInputChunks else {
                return .failed
            }
            entry.pendingInputs.append(input)
            entry.pendingInputBytes += input.count
            entriesBySurfaceID[surfaceID] = entry
            return .queued
        }
        do {
            try await lane.sendInput(input)
            guard entriesBySurfaceID[surfaceID]?.token == entry.token else {
                return .failed
            }
            return .sent
        } catch {
            await finish(
                surfaceID: surfaceID,
                token: entry.token,
                lane: lane,
                termination: .failed
            )
            return .failed
        }
    }

    func deactivate(surfaceID: String, token: UUID? = nil) async {
        guard let entry = entriesBySurfaceID[surfaceID],
              token == nil || token == entry.token else { return }
        entriesBySurfaceID[surfaceID] = nil
        entry.task?.cancel()
        await entry.lane?.close()
        await entry.task?.value
    }

    func deactivateAll(lifecycleID: UUID? = nil) async {
        let surfaceIDs = entriesBySurfaceID.compactMap { surfaceID, entry in
            lifecycleID == nil || entry.configuration.lifecycleID == lifecycleID
                ? surfaceID
                : nil
        }
        let entries = surfaceIDs.compactMap {
            entriesBySurfaceID.removeValue(forKey: $0)
        }
        for entry in entries { entry.task?.cancel() }
        for entry in entries { await entry.lane?.close() }
        for entry in entries { await entry.task?.value }
    }

    private func run(
        surfaceID: String,
        token: UUID,
        lane: any MobileTerminalSceneConnection
    ) async {
        var sawConfiguration = false
        var sawScene = false
        do {
            while !Task.isCancelled, let envelope = try await lane.receiveEnvelope() {
                guard let admitted = entriesBySurfaceID[surfaceID],
                      admitted.token == token else {
                    await lane.close()
                    return
                }
                let presented = try await admitted.configuration.consume(envelope)
                guard let entry = entriesBySurfaceID[surfaceID],
                      entry.token == token else {
                    await lane.close()
                    return
                }
                switch envelope {
                case .configuration:
                    sawConfiguration = true
                case .scene:
                    sawScene = true
                case .accessibility:
                    if sawConfiguration, sawScene, presented {
                        entriesBySurfaceID[surfaceID] = entry
                        try await flushPendingInput(
                            surfaceID: surfaceID,
                            token: token,
                            lane: lane
                        )
                    }
                }
            }
            guard !Task.isCancelled else { return }
            await finish(
                surfaceID: surfaceID,
                token: token,
                lane: lane,
                termination: .ended
            )
        } catch is CancellationError {
            return
        } catch {
            await finish(
                surfaceID: surfaceID,
                token: token,
                lane: lane,
                termination: .failed
            )
        }
    }

    private func flushPendingInput(
        surfaceID: String,
        token: UUID,
        lane: any MobileTerminalSceneConnection
    ) async throws {
        while true {
            guard var entry = entriesBySurfaceID[surfaceID],
                  entry.token == token else {
                throw CancellationError()
            }
            guard !entry.pendingInputs.isEmpty else {
                entry.ready = true
                entriesBySurfaceID[surfaceID] = entry
                return
            }
            let input = entry.pendingInputs.removeFirst()
            entry.pendingInputBytes -= input.count
            entriesBySurfaceID[surfaceID] = entry
            try await lane.sendInput(input)
        }
    }

    private func finish(
        surfaceID: String,
        token: UUID,
        lane: any MobileTerminalSceneConnection,
        termination: MobileTerminalSceneTermination
    ) async {
        guard let entry = entriesBySurfaceID[surfaceID],
              entry.token == token else {
            await lane.close()
            return
        }
        entriesBySurfaceID[surfaceID] = nil
        await lane.close()
        await entry.configuration.finished(token, termination)
    }
}
