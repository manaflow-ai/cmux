/// Captures a page's pixels when they change (ScreenCaptureKit on the Mac,
/// a synthetic source in tests). Idle pages produce no frames.
public protocol BrowserFrameCapture: Sendable {
    /// Changed frames, newest last. One consumer.
    func frames() async -> AsyncStream<BrowserCapturedFrame>
    /// Output size and rate for the frames that follow.
    func configure(pixelWidth: Int, pixelHeight: Int, maxFPS: Int) async throws
    func stop() async
}
