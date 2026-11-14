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
    private let shown: @MainActor (Int) -> Void
    private var decodeTask: Task<Void, Never>?
    private var webRTCFrames: ScreenVideoFrames?
    private var deliveryActive: MacScreenVideoLifetime?

    init(presenter: any RemoteFramePresenter, shown: @escaping @MainActor (Int) -> Void) {
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

    private func delivery() -> @Sendable (RemoteDecodedFrame) -> Void {
        let presenter = presenter
        let counter = MacScreenFrameCounter()
        // Callback cancellation fence: libwebrtc may already be delivering when detached.
        let active = MacScreenVideoLifetime()
        deliveryActive = active
        return { [weak self] frame in
            let report = active.deliver {
                presenter.present(frame)
                return counter.tick()
            }
            guard report else { return }
            MainDelivery().run { [weak self] in
                guard active.isActive else { return }
                self?.shown(counter.take())
            }
        }
    }

    func decode(_ transport: RemoteRdStreamTransport) {
        stop()
        let pipeline = RemoteDecodePipeline(source: transport, deliver: delivery())
        // task-owner: this transport's decoder; stops with the pane or its next carrier.
        decodeTask = Task.detached(priority: .userInitiated) { await pipeline.run() }
    }

    func present(_ track: VideoTrackBox) {
        stop()
        let deliver = delivery()
        webRTCFrames = ScreenVideoFrames(track: track) { buffer in
            deliver(RemoteDecodedFrame(pixelBuffer: buffer, frame: 0, tCaptureMicros: 0,
                                       decodedAtNanos: DispatchTime.now().uptimeNanoseconds))
        }
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
