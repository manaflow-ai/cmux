/// The frames of a VNC target as a `BrowserFrameCapture`: the target
/// publishes a pixel buffer whenever an update changed the visible region;
/// the shared `CapturedVideoSource` keeps the newest and encodes on demand.
actor RfbFrameCapture: BrowserFrameCapture {
    private let stream: AsyncStream<BrowserCapturedFrame>
    private let continuation: AsyncStream<BrowserCapturedFrame>.Continuation
    private(set) var pixelWidth = 0
    private(set) var pixelHeight = 0
    private var onConfigure: (@Sendable () async -> Void)?

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: BrowserCapturedFrame.self, bufferingPolicy: .bufferingNewest(1))
    }

    /// Called after every size change so the target can republish.
    func setOnConfigure(_ handler: @escaping @Sendable () async -> Void) {
        onConfigure = handler
    }

    func frames() -> AsyncStream<BrowserCapturedFrame> {
        stream
    }

    func configure(pixelWidth: Int, pixelHeight: Int, maxFPS: Int) async throws {
        let changed = (pixelWidth, pixelHeight) != (self.pixelWidth, self.pixelHeight)
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        if changed { await onConfigure?() }
    }

    func publish(_ frame: BrowserCapturedFrame) {
        continuation.yield(frame)
    }

    func stop() {
        continuation.finish()
    }
}
