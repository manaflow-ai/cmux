import CMUXMobileCore
import CmuxMobileRPC
import Foundation

/// Owns independent terminal lanes keyed by peer and mounted surface.
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

    private struct LaneKey: Hashable, Sendable {
        let peerIdentity: String
        let surfaceID: String

        init?(configuration: Configuration) {
            switch configuration.request.route.endpoint {
            case .peer(let identity, _):
                peerIdentity = identity.endpointID
            case .hostPort, .url:
                // LaneKey routes terminal input. Without a peer identity, two
                // peers sharing one route id would collapse into one lane and
                // cross-route input, so fail closed instead of defaulting.
                guard let expectedPeerDeviceID =
                        configuration.request.expectedPeerDeviceID,
                      !expectedPeerDeviceID.isEmpty else {
                    return nil
                }
                peerIdentity = [
                    expectedPeerDeviceID,
                    configuration.request.route.id,
                ].joined(separator: "|")
            }
            surfaceID = configuration.surfaceID
        }
    }

    private enum Phase {
        case opening
        case active
        case suspended
        case failed
    }

    private struct Entry {
        let id: UUID
        var configuration: Configuration
        var phase: Phase
        var lane: (any MobileTerminalLaneConnection)?
        var task: Task<Void, Never>?
        var outputReady: Bool
    }

    private static let maximumOpenAttempts = 3

    private let provider: MobileTerminalLaneProvider
    private var entriesByKey: [LaneKey: Entry] = [:]
    private var focusedKeyBySurfaceID: [String: LaneKey] = [:]

    init(provider: @escaping MobileTerminalLaneProvider) {
        self.provider = provider
    }

    func ensure(_ configuration: Configuration) async {
        guard let key = LaneKey(configuration: configuration) else { return }
        focusedKeyBySurfaceID[configuration.surfaceID] = key
        if var entry = entriesByKey[key] {
            entry.configuration = configuration
            entriesByKey[key] = entry
            if entry.outputReady {
                await configuration.readinessChanged(true)
            } else if entry.phase == .failed {
                entry.phase = .opening
                entriesByKey[key] = entry
                launch(key: key, id: entry.id)
            }
            return
        }
        let id = UUID()
        entriesByKey[key] = Entry(
            id: id,
            configuration: configuration,
            phase: .opening,
            lane: nil,
            task: nil,
            outputReady: false
        )
        launch(key: key, id: id)
    }

    func resume(surfaceID: String) {
        guard let key = focusedKeyBySurfaceID[surfaceID],
              var entry = entriesByKey[key],
              entry.phase == .suspended else {
            return
        }
        entry.phase = .opening
        entriesByKey[key] = entry
        launch(key: key, id: entry.id)
    }

    func sendInput(_ input: String, surfaceID: String) async -> InputResult {
        guard let key = focusedKeyBySurfaceID[surfaceID],
              let entry = entriesByKey[key],
              entry.phase == .active,
              entry.outputReady,
              let lane = entry.lane else {
            return .unavailable
        }
        do {
            try await lane.sendInput(input)
            guard let current = entriesByKey[key], current.id == entry.id else {
                return .failed
            }
            return .sent
        } catch {
            await fail(key: key, id: entry.id, lane: lane)
            return .failed
        }
    }

    /// Close every generation of one unmounted surface across all peers.
    func deactivate(surfaceID: String) async {
        focusedKeyBySurfaceID[surfaceID] = nil
        let keys = entriesByKey.keys.filter { $0.surfaceID == surfaceID }
        await deactivate(keys: keys)
    }

    /// Retire prior peers only after the currently focused peer has produced an
    /// authoritative replay frame.
    func retireUnfocusedLanes(surfaceID: String) async {
        guard let focusedKey = focusedKeyBySurfaceID[surfaceID],
              entriesByKey[focusedKey]?.outputReady == true else {
            return
        }
        let keys = entriesByKey.keys.filter {
            $0.surfaceID == surfaceID && $0 != focusedKey
        }
        await deactivate(keys: keys)
    }

    func deactivateAll() async {
        focusedKeyBySurfaceID.removeAll()
        await deactivate(keys: Array(entriesByKey.keys))
    }

    func isOutputReady(surfaceID: String) -> Bool {
        guard let key = focusedKeyBySurfaceID[surfaceID] else { return false }
        return entriesByKey[key]?.outputReady == true
    }

    private func deactivate(keys: [LaneKey]) async {
        let entries = keys.compactMap { key -> Entry? in
            entriesByKey.removeValue(forKey: key)
        }
        for entry in entries { entry.task?.cancel() }
        for entry in entries where entry.outputReady {
            await entry.configuration.readinessChanged(false)
        }
        for entry in entries { await entry.lane?.close() }
        for entry in entries { await entry.task?.value }
    }

    private func launch(key: LaneKey, id: UUID) {
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(key: key, id: id)
        }
        entriesByKey[key]?.task = task
    }

    private func run(key: LaneKey, id: UUID) async {
        var openAttempt = 0
        while openAttempt < Self.maximumOpenAttempts, !Task.isCancelled {
            guard let entry = entriesByKey[key], entry.id == id else { return }
            let configuration = entry.configuration
            let requestedCursor = await configuration.cursor()
            do {
                let lane = try await provider(
                    configuration.request,
                    configuration.surfaceID,
                    requestedCursor
                )
                guard install(lane: lane, key: key, id: id) else {
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
                    guard let currentConfiguration = entriesByKey[key]?
                            .configuration else {
                        await lane.close()
                        return
                    }
                    let disposition = await currentConfiguration.consume(frame)
                    guard let current = entriesByKey[key], current.id == id else {
                        await lane.close()
                        return
                    }
                    switch disposition {
                    case let .accepted(outputReady):
                        await setOutputReady(outputReady, key: key, id: id)
                    case .suspendUntilAuthoritativeOutput:
                        await suspend(key: key, id: id, lane: lane)
                        return
                    case .stop:
                        await finishFromRun(key: key, id: id, lane: lane)
                        return
                    }
                }
                if isFirstFrame {
                    throw CoordinatorError.missingReplayEnvelope
                }
                await prepareToReopen(key: key, id: id, lane: lane)
            } catch is CancellationError {
                return
            } catch {
                if let lane = entriesByKey[key]?.lane {
                    await prepareToReopen(key: key, id: id, lane: lane)
                } else {
                    await setOutputReady(false, key: key, id: id)
                }
            }
            openAttempt += 1
        }
        await markFailed(key: key, id: id)
    }

    private func install(
        lane: any MobileTerminalLaneConnection,
        key: LaneKey,
        id: UUID
    ) -> Bool {
        guard var entry = entriesByKey[key], entry.id == id else {
            return false
        }
        entry.phase = .active
        entry.lane = lane
        entriesByKey[key] = entry
        return true
    }

    private func setOutputReady(_ ready: Bool, key: LaneKey, id: UUID) async {
        guard var entry = entriesByKey[key], entry.id == id else { return }
        let changed = entry.outputReady != ready
        entry.outputReady = ready
        entriesByKey[key] = entry
        if changed {
            await entry.configuration.readinessChanged(ready)
        }
    }

    private func prepareToReopen(
        key: LaneKey,
        id: UUID,
        lane: any MobileTerminalLaneConnection
    ) async {
        guard var entry = entriesByKey[key], entry.id == id else {
            await lane.close()
            return
        }
        let wasReady = entry.outputReady
        entry.phase = .opening
        entry.lane = nil
        entry.outputReady = false
        entriesByKey[key] = entry
        if wasReady {
            await entry.configuration.readinessChanged(false)
        }
        await lane.close()
    }

    private func suspend(
        key: LaneKey,
        id: UUID,
        lane: any MobileTerminalLaneConnection
    ) async {
        guard var entry = entriesByKey[key], entry.id == id else {
            await lane.close()
            return
        }
        let wasReady = entry.outputReady
        entry.phase = .suspended
        entry.lane = nil
        entry.task = nil
        entry.outputReady = false
        entriesByKey[key] = entry
        if wasReady {
            await entry.configuration.readinessChanged(false)
        }
        await lane.close()
    }

    private func finishFromRun(
        key: LaneKey,
        id: UUID,
        lane: any MobileTerminalLaneConnection
    ) async {
        guard let entry = entriesByKey[key], entry.id == id else {
            await lane.close()
            return
        }
        entriesByKey[key] = nil
        if focusedKeyBySurfaceID[key.surfaceID] == key {
            focusedKeyBySurfaceID[key.surfaceID] = nil
        }
        if entry.outputReady {
            await entry.configuration.readinessChanged(false)
        }
        await lane.close()
    }

    private func fail(
        key: LaneKey,
        id: UUID,
        lane: any MobileTerminalLaneConnection
    ) async {
        guard var entry = entriesByKey[key], entry.id == id else {
            await lane.close()
            return
        }
        let wasReady = entry.outputReady
        entry.phase = .failed
        entry.lane = nil
        entry.task?.cancel()
        entry.task = nil
        entry.outputReady = false
        entriesByKey[key] = entry
        if wasReady {
            await entry.configuration.readinessChanged(false)
        }
        await lane.close()
    }

    private func markFailed(key: LaneKey, id: UUID) async {
        guard var entry = entriesByKey[key], entry.id == id else { return }
        let wasReady = entry.outputReady
        entry.phase = .failed
        entry.lane = nil
        entry.task = nil
        entry.outputReady = false
        entriesByKey[key] = entry
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
              frame.currentSequence - frame.sequence
                == UInt64(frame.bytes.count) else {
            throw CoordinatorError.invalidEnvelope
        }
    }
}
