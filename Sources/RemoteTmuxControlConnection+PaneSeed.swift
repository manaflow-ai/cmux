import Foundation

/// One bounded reset payload followed by equally bounded ordered parser writes.
/// The 2 MiB chunk ceiling matches cmuxd's external-terminal wire contract.
struct RemoteTmuxPaneSeed: Equatable, Sendable {
    static let maximumChunkByteCount = 2 * 1_024 * 1_024

    let reset: Data
    let output: [Data]

    init(bytes: Data) {
        var chunks = Self.chunks(bytes)
        reset = chunks.isEmpty ? Data() : chunks.removeFirst()
        output = chunks
    }

    init(reset: Data, output: [Data]) {
        precondition(reset.count <= Self.maximumChunkByteCount)
        precondition(output.allSatisfy { !$0.isEmpty && $0.count <= Self.maximumChunkByteCount })
        self.reset = reset
        self.output = output
    }

    init(orderedChunks: [Data]) {
        let chunks = orderedChunks.filter { !$0.isEmpty }
        precondition(chunks.allSatisfy { $0.count <= Self.maximumChunkByteCount })
        reset = chunks.first ?? Data()
        output = Array(chunks.dropFirst())
    }

    var bytes: Data {
        var combined = reset
        for chunk in output { combined.append(chunk) }
        return combined
    }

    private static func chunks(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }
        var result: [Data] = []
        result.reserveCapacity((data.count + maximumChunkByteCount - 1) / maximumChunkByteCount)
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(
                offset,
                offsetBy: min(maximumChunkByteCount, data.distance(from: offset, to: data.endIndex))
            )
            result.append(Data(data[offset..<end]))
            offset = end
        }
        return result
    }
}

struct RemoteTmuxPendingPaneSeed {
    enum Phase: Equatable {
        case awaitingCapture
        case captured
        /// The transaction was emitted early to bound memory, or failed. Its
        /// eventual pane-state reply is still owed before the next queued seed.
        case awaitingStateAfterEarlyCompletion
        case awaitingStateAfterFailure
    }

    var bytes: Data
    var phase: Phase = .awaitingCapture
}

@MainActor
extension RemoteTmuxControlConnection {
    /// Bounds bytes retained while tmux owes the pane-state result. Crossing the
    /// limit emits the seed immediately, then later bytes resume as live output.
    static let maximumPendingPaneSeedByteCount = 4 * RemoteTmuxPaneSeed.maximumChunkByteCount

    func beginPaneSeed(paneId: Int, clearScrollback: Bool) {
        let prefix = clearScrollback
            ? Data("\u{1b}[H\u{1b}[2J\u{1b}[3J".utf8)
            : Data()
        pendingPaneSeeds[paneId, default: []].append(
            RemoteTmuxPendingPaneSeed(bytes: prefix)
        )
    }

    func appendPaneSeedPrefix(paneId: Int, data: Data) {
        guard !data.isEmpty,
              pendingPaneSeeds[paneId]?.first?.phase == .awaitingCapture else { return }
        pendingPaneSeeds[paneId]![0].bytes.append(data)
    }

    func installPaneSeedCapture(paneId: Int, data: Data) {
        guard pendingPaneSeeds[paneId]?.isEmpty == false else {
            observers.emitPaneOutput(paneId, data)
            return
        }
        guard pendingPaneSeeds[paneId]![0].phase == .awaitingCapture else {
            observers.emitPaneOutput(paneId, data)
            return
        }
        pendingPaneSeeds[paneId]![0].bytes.append(data)
        pendingPaneSeeds[paneId]![0].phase = .captured
        emitPaneSeedEarlyIfNeeded(paneId: paneId)
    }

    /// Returns true when bytes were ordered after capture and retained in the
    /// pending transaction. Output before capture, after an early completion,
    /// or after failure remains ordinary live output.
    func absorbPaneOutputIntoPendingSeed(paneId: Int, data: Data) -> Bool {
        guard !data.isEmpty,
              pendingPaneSeeds[paneId]?.first?.phase == .captured else {
            return false
        }
        let retained = pendingPaneSeeds[paneId]![0].bytes.count
        if data.count > Self.maximumPendingPaneSeedByteCount - retained {
            emitPaneSeedEarlyIfNeeded(paneId: paneId, force: true)
            return false
        }
        pendingPaneSeeds[paneId]![0].bytes.append(data)
        return true
    }

    func finishPaneSeed(paneId: Int, state: Data) {
        guard var seeds = pendingPaneSeeds[paneId], !seeds.isEmpty else {
            if !state.isEmpty { observers.emitPaneOutput(paneId, state) }
            return
        }
        var completed = seeds.removeFirst()
        pendingPaneSeeds[paneId] = seeds.isEmpty ? nil : seeds
        switch completed.phase {
        case .awaitingCapture:
            observers.emitPaneSeedFailure(paneId)
            if !state.isEmpty { observers.emitPaneOutput(paneId, state) }
        case .captured:
            completed.bytes.append(state)
            observers.emitPaneSeed(paneId, RemoteTmuxPaneSeed(bytes: completed.bytes))
        case .awaitingStateAfterEarlyCompletion:
            if !state.isEmpty { observers.emitPaneOutput(paneId, state) }
        case .awaitingStateAfterFailure:
            if !state.isEmpty { observers.emitPaneOutput(paneId, state) }
        }
    }

    func failPaneSeedCommand(_ kind: CommandKind) {
        let paneId: Int
        switch kind {
        case .capturePane(let id), .paneState(let id): paneId = id
        case .paneAltScreen:
            return
        default:
            return
        }
        guard pendingPaneSeeds[paneId]?.isEmpty == false else { return }
        switch kind {
        case .capturePane:
            pendingPaneSeeds[paneId]![0].bytes.removeAll(keepingCapacity: false)
            pendingPaneSeeds[paneId]![0].phase = .awaitingStateAfterFailure
            observers.emitPaneSeedFailure(paneId)
        case .paneState:
            var seeds = pendingPaneSeeds[paneId]!
            let failed = seeds.removeFirst()
            pendingPaneSeeds[paneId] = seeds.isEmpty ? nil : seeds
            if failed.phase == .captured {
                observers.emitPaneSeed(paneId, RemoteTmuxPaneSeed(bytes: failed.bytes))
            } else if failed.phase == .awaitingCapture {
                observers.emitPaneSeedFailure(paneId)
            }
        default:
            break
        }
    }

    private func emitPaneSeedEarlyIfNeeded(paneId: Int, force: Bool = false) {
        guard pendingPaneSeeds[paneId]?.first?.phase == .captured,
              force || pendingPaneSeeds[paneId]![0].bytes.count > Self.maximumPendingPaneSeedByteCount
        else { return }
        let bytes = pendingPaneSeeds[paneId]![0].bytes
        pendingPaneSeeds[paneId]![0].bytes.removeAll(keepingCapacity: false)
        pendingPaneSeeds[paneId]![0].phase = .awaitingStateAfterEarlyCompletion
        observers.emitPaneSeed(paneId, RemoteTmuxPaneSeed(bytes: bytes))
    }

    func discardPendingPaneSeeds() {
        let paneIDs = Array(pendingPaneSeeds.keys)
        pendingPaneSeeds.removeAll(keepingCapacity: false)
        for paneID in paneIDs { observers.emitPaneSeedFailure(paneID) }
    }
}
