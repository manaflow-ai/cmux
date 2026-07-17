public import CmuxTerminalRenderTransport

/// Nonblocking command seam from one terminal surface to the process-wide
/// Ghostty render worker supervisor.
///
/// All producers use the supervisor's single ordered ingress, including the
/// Ghostty PTY read thread. Implementations must copy borrowed data before
/// returning and must never wait for the worker process.
public protocol TerminalRenderWorkerRouting: AnyObject, Sendable {
    /// Enqueues one versioned render-worker command.
    func enqueueRenderCommand(_ command: TerminalRenderWorkerCommand)
}

/// Default used by package tests and embedders that do not install a worker.
public final class DisabledTerminalRenderWorkerRouter: TerminalRenderWorkerRouting, @unchecked Sendable {
    /// Process-wide inert router.
    public static let shared = DisabledTerminalRenderWorkerRouter()

    private init() {}

    public func enqueueRenderCommand(_ command: TerminalRenderWorkerCommand) {}
}
