public import AppKit

#if DEBUG
/// History commands a remote tab sends to its host (`rb.history`).
public nonisolated enum RemoteBrowserHistoryOp: String, Sendable, Hashable {
    case back
    case forward
    case reload
    case stop
}

/// Where a remote tab's page-bound input and commands go: the rb/1 session
/// with the runtime host. The tab decides only what is the page's (after
/// the app's key router); the channel encodes and sends it.
@MainActor
public protocol RemoteBrowserPageChannel: AnyObject {
    /// Queues a key event for the page (in call order, without waiting) and
    /// returns a task for its input seq, which the host echoes in
    /// `rb.key_unhandled` when the page did not handle it; nil when the
    /// event was not sent.
    func sendKey(_ event: NSEvent) -> Task<UInt32?, Never>
    /// Sends a pointer event (modifiers and click count included) at
    /// `point`, in the page's CSS pixels.
    func sendPointer(_ event: NSEvent, at point: CGPoint)
    func history(_ op: RemoteBrowserHistoryOp)
    func setVisible(_ visible: Bool)
    /// Navigates the page to a typed or opened address.
    func load(_ url: URL)
    func close()
}
#endif
