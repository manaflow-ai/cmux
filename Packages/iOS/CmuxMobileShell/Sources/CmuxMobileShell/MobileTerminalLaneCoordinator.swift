import CMUXMobileCore
import CmuxMobileRPC
import Foundation

/// Owns one independent terminal lane per mounted Iroh surface.
actor MobileTerminalLaneCoordinator {
    enum FrameDisposition: Sendable {
        case accepted(outputReady: Bool)
        case suspendUntilAuthoritativeOutput
        case stop
    }

    enum InputResult: Equatable, Sendable {
        case unavailable
        case sent
        case failed
    }

    private enum CoordinatorError: Error {
        case missingReplayEnvelope
        case unexpectedReplayEnvelope
        case invalidEnvelope
        case replayCursorMismatch
    }

    struct Configuration: Sendable {
        let request: CmxByteTransportRequest
        let surfaceID: String
        let cursor: @Sendable () async -> UInt64?
        let consume: @Sendable (MobileTerminalLaneOutputFrame) async -> FrameDisposition
        let readinessChanged: @Sendable (Bool) async -> Void
    }

    private enum Phase {
        case opening
        case active
        case suspended
        case failed
    }

    private struct Entry {
        let id: UUID
        let configuration: Configuration
        var phase: Phase
        var lane: (any MobileTerminalLaneConnection)?
        var task: Task<Void, Never>?
        var outputReady: Bool
    }

    private static let maximumOpenAttempts = 3

    private let provider: MobileTerminalLaneProvider
    private var entriesBySurfaceID: [String: Entry] = [:]

    init(provider: @escaping MobileTerminalLaneProvider) {
        self.provider = provider
    }

    func ensure(_ configuration: Configuration) {
        guard entriesBySurfaceID[configuration.surfaceID] == nil else { return }
        let id = UUID()
        entriesBySurfaceID[configuration.surfaceID] = Entry(
            id: id,
            configuration: configuration,
            phase: .opening,
            lane: nil,
            task: nil,
            outputReady: false
        )
        launch(surfaceID: configuration.surfaceID, id: id)
    }

    func resume(surfaceID: String) {
        guard var entry = entriesBySurfaceID[surfaceID],
              entry.phase == .suspended else { return }
        entry.phase = .opening
        entriesBySurfaceID[surfaceID] = entry
        launch(surfaceID: surfaceID, id: entry.id)
    }

    func sendInput(_ input: String, surfaceID: String) async -> InputResult {
        guard let entry = entriesBySurfaceID[surfaceID],
              entry.phase == .active,
              entry.outputReady,
              let lane = entry.lane else {
            return .unavailable
        }
        do {
            try await lane.sendInput(input)
            guard let current = entriesBySurfaceID[surfaceID], current.id == entry.id else {
                return .failed
            }
            return .sent
        } catch {
            await fail(surfaceID: surfaceID, id: entry.id, lane: lane)
            return .failed
        }
    }

    func deactivate(surfaceID: String) async {
        guard let entry = entriesBySurfaceID.removeValue(forKey: surfaceID) else { return }
        entry.task?.cancel()
        if entry.outputReady {
            await entry.configuration.readinessChanged(false)
        }
        await entry.lane?.close()
        await entry.task?.value
    }

    func deactivateAll() async {
        let entries = Array(entriesBySurfaceID.values)
        entriesBySurfaceID.removeAll()
        for entry in entries { entry.task?.cancel() }
        for entry in entries where entry.outputReady {
            await entry.configuration.readinessChanged(false)
        }
        for entry in entries { await entry.lane?.close() }
        for entry in entries { await entry.task?.value }
    }

    func isOutputReady(surfaceID: String) -> Bool {
        entriesBySurfaceID[surfaceID]?.outputReady == true
    }

    private func launch(surfaceID: String, id: UUID) {
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(surfaceID: surfaceID, id: id)
        }
        entriesBySurfaceID[surfaceID]?.task = task
    }

    private func run(surfaceID: String, id: UUID) async {
        var openAttempt = 0
        while openAttempt < Self.maximumOpenAttempts, !Task.isCancelled {
            guard let entry = entriesBySurfaceID[surfaceID], entry.id == id else { return }
            let configuration = entry.configuration
            let requestedCursor = await configuration.cursor()
            do {
                let lane = try await provider(
                    configuration.request,
                    configuration.surfaceID,
                    requestedCursor
                )
                guard install(lane: lane, surfaceID: surfaceID, id: id) else {
                    await lane.close()
                    return
                }
                var isFirstFrame = true
                while !Task.isCancelled, let frame = try await lane.receiveOutput() {
                    try Self.validate(
                        frame,
                        isFirstFrame: isFirstFrame,
                        requestedCursor: requestedCursor
                    )
                    isFirstFrame = false
                    let disposition = await configuration.consume(frame)
                    guard let current = entriesBySurfaceID[surfaceID], current.id == id else {
                        await lane.close()
                        return
                    }
                    switch disposition {
                    case let .accepted(outputReady):
                        await setOutputReady(
                            outputReady,
                            surfaceID: surfaceID,
                            id: id
                        )
                    case .suspendUntilAuthoritativeOutput:
                        await suspend(surfaceID: surfaceID, id: id, lane: lane)
                        return
                    case .stop:
                        await finishFromRun(surfaceID: surfaceID, id: id, lane: lane)
                        return
                    }
                }
                if isFirstFrame {
                    throw CoordinatorError.missingReplayEnvelope
                }
                await prepareToReopen(surfaceID: surfaceID, id: id, lane: lane)
            } catch is CancellationError {
                return
            } catch {
                if let lane = entriesBySurfaceID[surfaceID]?.lane {
                    await prepareToReopen(surfaceID: surfaceID, id: id, lane: lane)
                } else {
                    await setOutputReady(false, surfaceID: surfaceID, id: id)
                }
            }
            openAttempt += 1
        }
        await markFailed(surfaceID: surfaceID, id: id)
    }

    private func install(
        lane: any MobileTerminalLaneConnection,
        surfaceID: String,
        id: UUID
    ) -> Bool {
        guard var entry = entriesBySurfaceID[surfaceID], entry.id == id else {
            return false
        }
        entry.phase = .active
        entry.lane = lane
        entriesBySurfaceID[surfaceID] = entry
        return true
    }

    private func setOutputReady(_ ready: Bool, surfaceID: String, id: UUID) async {
        guard var entry = entriesBySurfaceID[surfaceID], entry.id == id else { return }
        let changed = entry.outputReady != ready
        entry.outputReady = ready
        entriesBySurfaceID[surfaceID] = entry
        if changed {
            await entry.configuration.readinessChanged(ready)
        }
    }

    private func prepareToReopen(
        surfaceID: String,
        id: UUID,
        lane: any MobileTerminalLaneConnection
    ) async {
        guard var entry = entriesBySurfaceID[surfaceID], entry.id == id else {
            await lane.close()
            return
        }
        let wasReady = entry.outputReady
        entry.phase = .opening
        entry.lane = nil
        entry.outputReady = false
        entriesBySurfaceID[surfaceID] = entry
        if wasReady {
            await entry.configuration.readinessChanged(false)
        }
        await lane.close()
    }

    private func suspend(
        surfaceID: String,
        id: UUID,
        lane: any MobileTerminalLaneConnection
    ) async {
        guard var entry = entriesBySurfaceID[surfaceID], entry.id == id else {
            await lane.close()
            return
        }
        let wasReady = entry.outputReady
        entry.phase = .suspended
        entry.lane = nil
        entry.task = nil
        entry.outputReady = false
        entriesBySurfaceID[surfaceID] = entry
        if wasReady {
            await entry.configuration.readinessChanged(false)
        }
        await lane.close()
    }

    private func finishFromRun(
        surfaceID: String,
        id: UUID,
        lane: any MobileTerminalLaneConnection
    ) async {
        guard let entry = entriesBySurfaceID[surfaceID], entry.id == id else {
            await lane.close()
            return
        }
        entriesBySurfaceID[surfaceID] = nil
        if entry.outputReady {
            await entry.configuration.readinessChanged(false)
        }
        await lane.close()
    }

    private func fail(
        surfaceID: String,
        id: UUID,
        lane: any MobileTerminalLaneConnection
    ) async {
        guard var entry = entriesBySurfaceID[surfaceID], entry.id == id else {
            await lane.close()
            return
        }
        let wasReady = entry.outputReady
        entry.phase = .failed
        entry.lane = nil
        entry.task?.cancel()
        entry.task = nil
        entry.outputReady = false
        entriesBySurfaceID[surfaceID] = entry
        if wasReady {
            await entry.configuration.readinessChanged(false)
        }
        await lane.close()
    }

    private func markFailed(surfaceID: String, id: UUID) async {
        guard var entry = entriesBySurfaceID[surfaceID], entry.id == id else { return }
        let wasReady = entry.outputReady
        entry.phase = .failed
        entry.lane = nil
        entry.task = nil
        entry.outputReady = false
        entriesBySurfaceID[surfaceID] = entry
        if wasReady {
            await entry.configuration.readinessChanged(false)
        }
    }

    private static func validate(
        _ frame: MobileTerminalLaneOutputFrame,
        isFirstFrame: Bool,
        requestedCursor: UInt64?
    ) throws {
        if isFirstFrame {
            guard frame.kind == .replay else {
                throw CoordinatorError.missingReplayEnvelope
            }
            if let requestedCursor, frame.sequence != requestedCursor {
                throw CoordinatorError.replayCursorMismatch
            }
        } else if frame.kind == .replay {
            throw CoordinatorError.unexpectedReplayEnvelope
        }
        guard frame.retainedBaseSequence <= frame.sequence,
              frame.sequence <= frame.currentSequence,
              frame.currentSequence - frame.sequence == UInt64(frame.bytes.count) else {
            throw CoordinatorError.invalidEnvelope
        }
    }
}
