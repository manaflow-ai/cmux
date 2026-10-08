public import AppKit
public import CmuxNextRemoteView
import Synchronization

#if DEBUG
/// One remote tab's page: owns the decode pipeline from a stream source to
/// the presenter. Session state (menus, dialogs, cursor) lives in the Rust
/// client reducer; this type only moves frames and reports sizes.
@MainActor
public final class RemoteBrowserPane {
    public let view = RemoteBrowserContentView()
    private let source: any RemoteViewStreamSource
    private let presenter: any RemoteFramePresenter
    private var pipelineTask: Task<Void, Never>?
    private var delivery: DeliveryGate?
    private var sizeContinuations: [AsyncStream<CGSize>.Continuation] = []

    public convenience init(source: any RemoteViewStreamSource, presenter: RemotePresenterKind = .layerContents) {
        self.init(source: source, presenter: RemoteFramePresenters().make(presenter))
    }

    /// `presenter` receives every decoded frame (tests pass a recorder).
    package init(source: any RemoteViewStreamSource, presenter: any RemoteFramePresenter) {
        self.source = source
        self.presenter = presenter
        view.video.install(self.presenter)
        self.presenter.onFrameSize = { [weak self] size in self?.frameSizeChanged(size) }
    }

    /// Decoded frame sizes in device pixels, one value per change. Finishes
    /// at `stop()`.
    public func frameSizes() -> AsyncStream<CGSize> {
        let (stream, continuation) = AsyncStream.makeStream(of: CGSize.self, bufferingPolicy: .bufferingNewest(4))
        sizeContinuations.append(continuation)
        return stream
    }

    public func start() {
        guard pipelineTask == nil else { return }
        let presenter = self.presenter
        let gate = DeliveryGate()
        delivery = gate
        let pipeline = RemoteDecodePipeline(source: source) { frame in gate.deliver(frame, to: presenter) }
        pipelineTask = Task.detached(priority: .userInitiated) { await pipeline.run() }
    }

    /// After this returns no frame reaches the presenter, even one whose
    /// decode was in flight. The source sees the stop when the pipeline
    /// stops reading its access units (the stream terminates).
    public func stop() {
        delivery?.close()
        delivery = nil
        pipelineTask?.cancel()
        pipelineTask = nil
        for continuation in sizeContinuations { continuation.finish() }
        sizeContinuations.removeAll()
    }

    private func frameSizeChanged(_ size: CGSize) {
        view.video.setFramePixels(size)
        for continuation in sizeContinuations { continuation.yield(size) }
    }
}

/// Passes decoded frames to the presenter until closed. A frame is presented
/// inside the lock, so `close()` waits for a present in progress and none
/// starts after it returns.
private nonisolated final class DeliveryGate: Sendable {
    private let open = Mutex(true)

    func deliver(_ frame: RemoteDecodedFrame, to presenter: any RemoteFramePresenter) {
        open.withLock { open in
            if open { presenter.present(frame) }
        }
    }

    func close() {
        open.withLock { $0 = false }
    }
}
#endif
