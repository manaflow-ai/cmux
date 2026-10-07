/// A `BrowserVideoSource` over a capture and an encoder: keeps only the
/// newest captured frame (newest wins), encodes when the handler pulls, and
/// re-encodes the last frame when a keyframe is requested on an idle page.
public actor CapturedVideoSource: BrowserVideoSource {
    private let capture: any BrowserFrameCapture
    private let encoder: any BrowserFrameEncoder
    private var latest: BrowserCapturedFrame?
    private var dirty = false
    private var keyframeRequested = true
    private var ended = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var pump: Task<Void, Never>?
    private var configured: (width: Int, height: Int, fps: Int)?

    public init(capture: any BrowserFrameCapture, encoder: any BrowserFrameEncoder) {
        self.capture = capture
        self.encoder = encoder
    }

    public func nextFrame(_ request: BrowserFrameRequest) async throws -> BrowserEncodedFrame? {
        startIfNeeded()
        if configured.map({ $0 != (request.pixelWidth, request.pixelHeight, request.maxFPS) }) ?? true {
            configured = (request.pixelWidth, request.pixelHeight, request.maxFPS)
            try await capture.configure(pixelWidth: request.pixelWidth, pixelHeight: request.pixelHeight, maxFPS: request.maxFPS)
            keyframeRequested = true
        }
        while true {
            if ended { return nil }
            // The capture may still emit the previous size right after a
            // resize; the encoder follows the frame's size either way.
            if let frame = latest, dirty || keyframeRequested {
                let force = keyframeRequested
                dirty = false
                keyframeRequested = false
                if let encoded = try await encoder.encode(frame, bitrate: request.bitrate, maxFPS: request.maxFPS,
                                                          forceKeyframe: force) {
                    return encoded
                }
                continue
            }
            try Task.checkCancellation()
            await withTaskCancellationHandler {
                await withCheckedContinuation { waiter = $0 }
            } onCancel: {
                Task { await self.wake() }
            }
        }
    }

    public func requestKeyframe() {
        keyframeRequested = true
        wake()
    }

    public func stop() async {
        ended = true
        pump?.cancel()
        wake()
        await capture.stop()
        await encoder.close()
    }

    private func startIfNeeded() {
        guard pump == nil else { return }
        let capture = capture
        pump = Task { [weak self] in
            for await frame in await capture.frames() {
                await self?.received(frame)
            }
            await self?.captureEnded()
        }
    }

    private func received(_ frame: BrowserCapturedFrame) {
        latest = frame
        dirty = true
        wake()
    }

    private func captureEnded() {
        ended = true
        wake()
    }

    private func wake() {
        waiter?.resume()
        waiter = nil
    }
}
