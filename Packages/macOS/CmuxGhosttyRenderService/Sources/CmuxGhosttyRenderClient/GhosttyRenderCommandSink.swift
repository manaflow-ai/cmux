public import CmuxTerminalRenderTransport
internal import Dispatch

/// Thread-safe, totally ordered ingress for terminal renderer commands.
///
/// Ghostty PTY output arrives on I/O threads while AppKit mutations arrive on
/// the main actor. Both enter this one serial queue before the client actor
/// consumes them, preventing unstructured Tasks from reordering output,
/// resize, focus, and pointer changes.
public final class GhosttyRenderCommandSink: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "dev.cmux.ghostty-render.command-outbox",
        qos: .userInitiated
    )
    private let continuation: AsyncStream<TerminalRenderWorkerCommand>.Continuation
    let stream: AsyncStream<TerminalRenderWorkerCommand>

    init() {
        let pair = AsyncStream.makeStream(
            of: TerminalRenderWorkerCommand.self,
            bufferingPolicy: .unbounded
        )
        self.stream = pair.stream
        self.continuation = pair.continuation
    }

    /// Adds one command to the global worker ordering lane without blocking
    /// the caller on process I/O.
    public func enqueue(_ command: TerminalRenderWorkerCommand) {
        queue.async { [continuation] in
            continuation.yield(command)
        }
    }

    /// Ends the ordering lane during client shutdown.
    func finish() {
        queue.async { [continuation] in
            continuation.finish()
        }
    }
}
