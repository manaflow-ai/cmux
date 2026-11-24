import CmuxNextRemoteView
import CmuxNextCompat
import CmuxNextWakeups
import CmuxScreenKit
import Dispatch

/// Both carriers feed the pane's existing presenter. Decoding and presentation
/// stay off the main actor; only batched frame counts return to the pane.
@MainActor
final class MacScreenVideo {
    private let presenter: any RemoteFramePresenter
    private var decodeTask: Task<Void, Never>?
    private var webRTCFrames: ScreenVideoFrames?
    private var deliveryActive: MacScreenVideoLifetime?

    private let shown: @MainActor (MacScreenFrameCounter) -> Void

    init(presenter: any RemoteFramePresenter, shown: @escaping @MainActor (MacScreenFrameCounter) -> Void) {
        self.presenter = presenter
        self.shown = shown
    }

    func stop() {
        deliveryActive?.cancel()
        deliveryActive = nil
        decodeTask?.cancel()
        decodeTask = nil
        webRTCFrames = nil
    }

    private func delivery(_ counter: MacScreenFrameCounter) -> @Sendable (RemoteDecodedFrame) -> Void {
        let presenter = presenter
        // Callback cancellation fence: libwebrtc may already be delivering when detached.
        let active = MacScreenVideoLifetime()
        deliveryActive = active
        return { [weak self] frame in
            // The stats and the first picture, without a main-actor hop per frame.
            let report = active.deliver {
                presenter.present(frame)
                return counter.tick(frame: frame.frame, releasedAtNanos: frame.releasedAtNanos,
                                    decodedAtNanos: frame.decodedAtNanos)
            }
            guard report else { return }
            MainDelivery().run { [weak self] in
                guard active.isActive else { return }
                self?.shown(counter)
            }
        }
    }

    /// Decodes an rd/1 transport's video into the presenter; returns the session's frame counter.
    func decode(_ transport: RemoteRdStreamTransport) -> MacScreenFrameCounter {
        stop()
        let counter = MacScreenFrameCounter()
        let pipeline = RemoteDecodePipeline(source: transport, deliver: delivery(counter), presented: { counter.shown($0) })
        // task-owner: this transport's decoder; stops with the pane or its next carrier.
        decodeTask = Task.detached(priority: .userInitiated) { await pipeline.run() }
        return counter
    }

    /// Presents a WebRTC fallback track through the same presenter; returns its frame counter.
    func present(_ track: VideoTrackBox) -> MacScreenFrameCounter {
        stop()
        let counter = MacScreenFrameCounter()
        let deliver = delivery(counter)
        webRTCFrames = ScreenVideoFrames(track: track) { buffer in
            deliver(RemoteDecodedFrame(pixelBuffer: buffer, frame: 0, tCaptureMicros: 0,
                                       decodedAtNanos: DispatchTime.now().uptimeNanoseconds))
        }
        return counter
    }
}

/// Serializes callback delivery with cancellation without holding a lock over an await.
private nonisolated final class MacScreenVideoLifetime: Sendable {
    private let active = Mutex(true)
    var isActive: Bool { active.load() }
    func cancel() { active.store(false) }
    func deliver(_ frame: () -> Bool) -> Bool {
        active.withLock { $0 ? frame() : false }
    }
}
