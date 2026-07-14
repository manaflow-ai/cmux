public import CMUXMobileCore
public import Foundation

/// A seam exposing per-surface terminal output as an `AsyncStream`.
///
/// A mounted terminal view obtains the stream for its surface, feeds each
/// yielded chunk into its libghostty surface (`process_output`), then calls
/// ``terminalOutputDidProcess(surfaceID:streamToken:)``. The bytes are VT patch bytes
/// derived from render-grid frames, or raw PTY bytes as a compatibility fallback
/// for older Mac hosts. Obtaining the stream also arms a cold-attach replay so a
/// freshly mounted surface catches up to current state; ending iteration
/// releases the surface so the Mac drops its viewport pin.
///
/// This replaces the previous `(Data) -> Void` sink registry so output
/// propagation is a structured, cancellable `AsyncSequence` instead of a stored
/// callback. Chunks may also carry a viewport policy so primary-screen output can
/// use the phone's natural height while alternate-screen replay remains pinned
/// to the remote grid.
public enum MobileTerminalOutputViewportPolicy: Equatable, Sendable {
    case natural
    case remoteGrid(columns: Int, rows: Int)
}

public struct MobileTerminalOutputOperation: Equatable, Sendable {
    public let data: Data
    public let viewportPolicy: MobileTerminalOutputViewportPolicy?
    public let scrollbackOffsetFromBottomRows: Int?
    public let followingScrollRuns: [MobileTerminalScrollRun]

    public init(
        data: Data,
        viewportPolicy: MobileTerminalOutputViewportPolicy? = nil,
        scrollbackOffsetFromBottomRows: Int? = nil,
        followingScrollRuns: [MobileTerminalScrollRun] = []
    ) {
        self.data = data
        self.viewportPolicy = viewportPolicy
        self.scrollbackOffsetFromBottomRows = scrollbackOffsetFromBottomRows.map { max(0, $0) }
        self.followingScrollRuns = followingScrollRuns
    }
}

/// One causally ordered operation for a mounted terminal surface.
public enum MobileTerminalSurfaceMutation: Equatable, Sendable {
    case output(MobileTerminalOutputOperation)
    case localScroll([MobileTerminalScrollRun])
    case scrollToBottom
    case barrier
}

public struct MobileTerminalOutputChunk: Sendable {
    public let mutation: MobileTerminalSurfaceMutation
    public let streamToken: UUID
    /// Identifies this exact yielded delivery inside the stream generation.
    /// The consumer claims it before touching Ghostty so a newer scroll can
    /// discard a yielded-but-not-started viewport repaint.
    public let deliveryID: UUID
    public var data: Data {
        guard case .output(let operation) = mutation else { return Data() }
        return operation.data
    }

    public var viewportPolicy: MobileTerminalOutputViewportPolicy? {
        guard case .output(let operation) = mutation else { return nil }
        return operation.viewportPolicy
    }
    /// Rows newer than a full authoritative primary-screen viewport. `nil`
    /// preserves the current position for raw bytes and delta frames; zero is
    /// an explicit bottom position after a full history rebuild.
    public var scrollbackOffsetFromBottomRows: Int? {
        guard case .output(let operation) = mutation else { return nil }
        return operation.scrollbackOffsetFromBottomRows
    }

    public init(
        data: Data,
        streamToken: UUID,
        deliveryID: UUID = UUID(),
        viewportPolicy: MobileTerminalOutputViewportPolicy? = nil,
        scrollbackOffsetFromBottomRows: Int? = nil
    ) {
        self.mutation = .output(MobileTerminalOutputOperation(
            data: data,
            viewportPolicy: viewportPolicy,
            scrollbackOffsetFromBottomRows: scrollbackOffsetFromBottomRows
        ))
        self.streamToken = streamToken
        self.deliveryID = deliveryID
    }

    public init(
        mutation: MobileTerminalSurfaceMutation,
        streamToken: UUID,
        deliveryID: UUID = UUID()
    ) {
        self.mutation = mutation
        self.streamToken = streamToken
        self.deliveryID = deliveryID
    }
}

public protocol MobileTerminalOutputSinking: Sendable {
    /// The output byte stream for a terminal surface.
    ///
    /// - Parameter surfaceID: The terminal surface identifier.
    /// - Returns: An `AsyncStream` of output chunks. Ending iteration (or
    ///   cancelling the consuming task) unregisters the surface.
    @MainActor func terminalOutputStream(surfaceID: String) -> AsyncStream<MobileTerminalOutputChunk>

    /// Mark the current yielded chunk as applied, allowing the next buffered
    /// chunk for the same surface to be yielded.
    /// - Parameter surfaceID: The terminal surface identifier.
    /// - Parameter streamToken: The token carried by the yielded chunk.
    @MainActor func terminalOutputDidProcess(surfaceID: String, streamToken: UUID)

    /// Abandon the current yielded chunk after the local renderer was reset.
    ///
    /// The sink must drop stale pending output, invalidate the old stream token,
    /// and request an authoritative replay for the same surface.
    /// - Parameter surfaceID: The terminal surface identifier.
    /// - Parameter streamToken: The token carried by the abandoned chunk.
    @MainActor func terminalOutputDidReset(surfaceID: String, streamToken: UUID)

    /// Request an authoritative replay without an abandoned in-flight chunk.
    /// - Parameter surfaceID: The terminal surface identifier.
    @MainActor func terminalOutputNeedsReplay(surfaceID: String)
}
