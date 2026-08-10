import Foundation

enum RemoteTmuxPaneSeedKind: Equatable, Sendable {
    case fullHistory
    case visibleRepaint
}

/// One authoritative pane snapshot and the live-stream bytes around its tmux
/// command-result boundary.
///
/// `discardedOutput` happened before tmux completed `capture-pane`, so its cells
/// are already represented by `snapshot`. `catchUpOutput` happened after that
/// boundary and must be replayed once after restoring the boundary `state`.
/// Keeping the groups typed is
/// also important for stateful escape filters: a snapshot is not a continuation
/// of an incomplete live escape sequence.
struct RemoteTmuxPaneSeed: Equatable, Sendable {
    /// The daemon external-terminal wire limit for one reset or output write.
    static let maximumChunkByteCount = 2 * 1_024 * 1_024

    let kind: RemoteTmuxPaneSeedKind
    let discardedOutput: [Data]
    let snapshot: Data
    let catchUpOutput: [Data]
    let state: Data

    init(
        kind: RemoteTmuxPaneSeedKind,
        discardedOutput: [Data],
        snapshot: Data,
        catchUpOutput: [Data],
        state: Data
    ) {
        self.kind = kind
        self.discardedOutput = discardedOutput
        self.snapshot = snapshot
        self.catchUpOutput = catchUpOutput
        self.state = state
    }

    /// Builds a bounded daemon seed from one already-rendered byte stream.
    init(bytes: Data) {
        var chunks = Self.boundedChunks(bytes)
        self.init(
            kind: .fullHistory,
            discardedOutput: [],
            snapshot: chunks.isEmpty ? Data() : chunks.removeFirst(),
            catchUpOutput: chunks,
            state: Data()
        )
    }

    /// Compatibility projection used only by the persistent backend bridge.
    var reset: Data { snapshot }
    var output: [Data] {
        let stateChunks = Self.boundedChunks(state)
        return stateChunks + catchUpOutput.flatMap(Self.boundedChunks)
    }

    /// Compatibility projection for observers that have not registered a typed
    /// seed callback. Pre-snapshot live bytes are intentionally omitted.
    var renderedBytes: Data {
        var bytes = snapshot
        bytes.append(state)
        for chunk in catchUpOutput { bytes.append(chunk) }
        return bytes
    }

    static func boundedChunks(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }
        var result: [Data] = []
        result.reserveCapacity((data.count + maximumChunkByteCount - 1) / maximumChunkByteCount)
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(
                offset,
                offsetBy: min(
                    maximumChunkByteCount,
                    data.distance(from: offset, to: data.endIndex)
                )
            )
            result.append(Data(data[offset ..< end]))
            offset = end
        }
        return result
    }
}
