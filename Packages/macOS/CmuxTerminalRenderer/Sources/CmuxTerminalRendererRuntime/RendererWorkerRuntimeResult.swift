public import CmuxTerminalRendererControl

/// Replies and lifecycle disposition produced by one accepted daemon command.
public struct RendererWorkerRuntimeResult: Sendable {
    public let replies: [RendererControlMessage]
    public let shouldExit: Bool

    public init(replies: [RendererControlMessage] = [], shouldExit: Bool = false) {
        self.replies = replies
        self.shouldExit = shouldExit
    }
}
