public import CmuxNextPages

/// A ``PageRendererProcess`` several ``FakeChromiumPage``s can share (pages in one renderer, as
/// Chromium keeps agent chats): it records the host's ends and restarts, and the test decides
/// what each answers.
@MainActor
public final class FakeRendererProcess: PageRendererProcess {
    public var isUnresponsive = false
    public var rendererClientID: Int32?
    public var rendererProcessID: Int32?
    public var isBeingDebugged = false
    /// What ``endRenderer()`` answers: the pid ended; nil: nothing ended.
    public var endAnswer: Int32? = 4242
    /// How often the host ended the renderer.
    public private(set) var ends = 0
    /// How often App Health restarted it.
    public private(set) var restarts = 0

    public init(clientID: Int32? = 7, pid: Int32? = 4242) {
        rendererClientID = clientID
        rendererProcessID = pid
    }

    public func restartRenderer() { restarts += 1 }

    public func endRenderer() -> Int32? {
        ends += 1
        return endAnswer
    }
}
