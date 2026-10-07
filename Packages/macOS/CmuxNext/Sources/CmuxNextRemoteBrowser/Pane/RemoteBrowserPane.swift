public import AppKit
public import CmuxNextRemoteView

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
    private var sizeContinuations: [AsyncStream<CGSize>.Continuation] = []

    public init(source: any RemoteViewStreamSource, presenter: RemotePresenterKind = .layerContents) {
        self.source = source
        self.presenter = RemoteFramePresenters().make(presenter)
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
        let pipeline = RemoteDecodePipeline(source: source) { frame in presenter.present(frame) }
        pipelineTask = Task.detached(priority: .userInitiated) { await pipeline.run() }
    }

    public func stop() {
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
#endif
