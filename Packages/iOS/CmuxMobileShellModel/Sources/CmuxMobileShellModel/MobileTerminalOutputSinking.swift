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

public struct MobileTerminalOutputChunk: Sendable {
    public let data: Data
    public let streamToken: UUID
    public let viewportPolicy: MobileTerminalOutputViewportPolicy?
    /// Source grid whose VT replay bytes are carried by this chunk.
    public let sourceRenderGridFrame: MobileTerminalRenderGridFrame?
    /// Whether nonempty output must pass render-grid verification before display.
    public let requiresVerifiedReplay: Bool
    /// Raw Ghostty defaults that must be installed before this chunk's VT replay.
    public let terminalConfigTheme: TerminalTheme?

    public init(
        data: Data,
        streamToken: UUID,
        viewportPolicy: MobileTerminalOutputViewportPolicy? = nil,
        sourceRenderGridFrame: MobileTerminalRenderGridFrame? = nil,
        requiresVerifiedReplay: Bool = false,
        terminalConfigTheme: TerminalTheme? = nil
    ) {
        self.data = data
        self.streamToken = streamToken
        self.viewportPolicy = viewportPolicy
        self.sourceRenderGridFrame = sourceRenderGridFrame
        self.requiresVerifiedReplay = requiresVerifiedReplay
        self.terminalConfigTheme = terminalConfigTheme
    }
}

/// Cancellable terminal-output sequence with deterministic surface teardown.
///
/// `AsyncStream` termination is not prompt enough when the producer stores the
/// continuation while a replay RPC is suspended. This wrapper keeps the same
/// `for await` call site and exposes an explicit `cancel()` lease for view
/// teardown.
public struct MobileTerminalOutputStream: AsyncSequence, Sendable {
    public typealias Element = MobileTerminalOutputChunk

    public final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var didCancel = false
        private var handler: (@Sendable () -> Void)?

        public init() {}

        public func install(_ handler: @escaping @Sendable () -> Void) {
            var shouldRunNow = false
            lock.lock()
            if didCancel {
                shouldRunNow = true
            } else {
                self.handler = handler
            }
            lock.unlock()
            if shouldRunNow {
                handler()
            }
        }

        public func cancel() {
            let handlerToRun: (@Sendable () -> Void)?
            lock.lock()
            if didCancel {
                handlerToRun = nil
            } else {
                didCancel = true
                handlerToRun = handler
                handler = nil
            }
            lock.unlock()
            handlerToRun?()
        }
    }

    public final class Iterator: AsyncIteratorProtocol, @unchecked Sendable {
        private let cancellation: Cancellation
        private var baseIterator: AsyncStream<Element>.Iterator?

        fileprivate init(
            baseIterator: AsyncStream<Element>.Iterator,
            cancellation: Cancellation
        ) {
            self.baseIterator = baseIterator
            self.cancellation = cancellation
        }

        deinit {
            cancellation.cancel()
        }

        public func next() async -> Element? {
            if Task.isCancelled {
                cancellation.cancel()
                return nil
            }
            let cancellation = cancellation
            let element: Element? = await withTaskCancellationHandler {
                guard var iterator = baseIterator else { return nil }
                let element = await iterator.next()
                baseIterator = iterator
                return element
            } onCancel: {
                cancellation.cancel()
            }
            if element == nil {
                cancellation.cancel()
            }
            return element
        }
    }

    private let stream: AsyncStream<Element>
    private let cancellation: Cancellation

    public init(
        _ build: (
            AsyncStream<Element>.Continuation,
            Cancellation
        ) -> Void
    ) {
        let cancellation = Cancellation()
        self.cancellation = cancellation
        self.stream = AsyncStream<Element> { continuation in
            build(continuation, cancellation)
        }
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(
            baseIterator: stream.makeAsyncIterator(),
            cancellation: cancellation
        )
    }

    public func cancel() {
        cancellation.cancel()
    }
}

public protocol MobileTerminalOutputSinking: Sendable {
    /// The output byte stream for a terminal surface.
    ///
    /// - Parameter surfaceID: The terminal surface identifier.
    /// - Returns: A cancellable output sequence. The mounted view must call
    ///   `cancel()` when the surface detaches.
    @MainActor func terminalOutputStream(surfaceID: String) -> MobileTerminalOutputStream

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
