import Foundation

/// Per-surface mobile-terminal byte/replay state shared by the Mac host paths.
///
/// The app owns terminal surfaces, transport subscriptions, render scheduling,
/// and event fan-out. This store owns only value/state-machine behavior so edits
/// to replay retention, stream cursors, render capture identity, or accepted-input
/// watermarks can compile independently of the app target.
public final class MobileTerminalStreamStateStore {
    private struct SurfaceState {
        /// Monotonic byte-stream sequence. Each append advances by byte count.
        var sequence: UInt64 = 0
        /// Tail-trimmed replay bytes retained for cold attach.
        var replayBuffer = Data()
        /// Unique lifetime of this surface's render revision sequence.
        var renderEpoch = UUID().uuidString
        /// Producer capture order, independent of byte sequence.
        var renderRevision: UInt64 = 0
        /// Opaque marker of the latest accepted input.
        var inputSequence: UInt64?
    }

    private let replayBudget: Int
    private var statesBySurfaceID: [UUID: SurfaceState] = [:]

    /// Creates an empty store retaining at most `replayBudget` bytes per surface.
    public init(replayBudget: Int = 256 * 1024) {
        precondition(replayBudget >= 0)
        self.replayBudget = replayBudget
    }

    /// Returns the retained byte tail and the current byte cursor for a surface.
    @MainActor
    public func replayState(surfaceID: UUID) -> (seq: UInt64, data: Data)? {
        guard let state = statesBySurfaceID[surfaceID] else { return nil }
        return (state.sequence, state.replayBuffer)
    }

    /// Returns the current byte cursor when state exists for the surface.
    @MainActor
    public func currentSequence(surfaceID: UUID) -> UInt64? {
        statesBySurfaceID[surfaceID]?.sequence
    }

    /// Records an input marker only when the app reports that input as accepted.
    @MainActor
    public func recordAcceptedInput(surfaceID: UUID, sequence: UInt64?, accepted: Bool) {
        guard accepted else { return }
        var state = statesBySurfaceID[surfaceID] ?? SurfaceState()
        state.inputSequence = sequence
        statesBySurfaceID[surfaceID] = state
    }

    /// Returns the latest accepted input marker for the surface.
    @MainActor
    public func currentInputSequence(surfaceID: UUID) -> UInt64? {
        statesBySurfaceID[surfaceID]?.inputSequence
    }

    /// Returns the current render-capture identity, creating surface state when absent.
    @MainActor
    public func currentRenderCaptureIdentity(surfaceID: UUID) -> (epoch: String, revision: UInt64) {
        let state = statesBySurfaceID[surfaceID] ?? SurfaceState()
        statesBySurfaceID[surfaceID] = state
        return (epoch: state.renderEpoch, revision: state.renderRevision)
    }

    /// Claims the next render-capture revision in this surface lifetime.
    @MainActor
    public func nextRenderCaptureIdentity(surfaceID: UUID) -> (epoch: String, revision: UInt64) {
        var state = statesBySurfaceID[surfaceID] ?? SurfaceState()
        state.renderRevision &+= 1
        if state.renderRevision == 0 {
            state.renderRevision = 1
        }
        statesBySurfaceID[surfaceID] = state
        return (epoch: state.renderEpoch, revision: state.renderRevision)
    }

    /// Appends one raw terminal-output chunk and returns its byte-cursor bounds.
    @MainActor
    @discardableResult
    public func append(surfaceID: UUID, data: Data) -> MobileTerminalStreamAppendResult {
        var state = statesBySurfaceID[surfaceID] ?? SurfaceState()
        let chunkSequence = state.sequence
        state.sequence &+= UInt64(data.count)
        state.replayBuffer.append(data)
        if state.replayBuffer.count > replayBudget {
            state.replayBuffer.removeFirst(state.replayBuffer.count - replayBudget)
        }
        statesBySurfaceID[surfaceID] = state
        return MobileTerminalStreamAppendResult(
            chunkSequence: chunkSequence,
            currentSequence: state.sequence
        )
    }

    /// Drops all byte, render, and input-watermark state for a closed surface.
    @MainActor
    public func removeSurface(surfaceID: UUID) {
        statesBySurfaceID.removeValue(forKey: surfaceID)
    }
}

/// Cursor values produced by one terminal-byte append.
public struct MobileTerminalStreamAppendResult: Equatable, Sendable {
    /// Cursor of the first byte in the appended chunk.
    public let chunkSequence: UInt64
    /// Cursor immediately after the appended chunk.
    public let currentSequence: UInt64

    public init(chunkSequence: UInt64, currentSequence: UInt64) {
        self.chunkSequence = chunkSequence
        self.currentSequence = currentSequence
    }
}
