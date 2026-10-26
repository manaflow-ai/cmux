public import AppKit
public import CmuxNextRemoteView
import CmuxNextCompat

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
    private var delivery: RemoteFrameGate?
    private var sizeContinuations: [AsyncStream<CGSize>.Continuation] = []
    /// The session ended (`stop()`): the pane never decodes again.
    private var ended = false
    /// Runs on the main actor when a started pipeline presents its first frame (a woken tab's
    /// picture then goes, `BrowserWakeCover`).
    public var onFirstFrame: (() -> Void)?

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

    /// Decodes and presents the source's frames. Idempotent; nothing after `stop()`. A new
    /// pipeline subscribes again and waits for a keyframe, which it asks the source for.
    public func start() {
        guard pipelineTask == nil, !ended else { return }
        let presenter = self.presenter
        let gate = RemoteFrameGate()
        delivery = gate
        let pipeline = RemoteDecodePipeline(source: source) { [weak self] frame in
            guard gate.deliver(frame, to: presenter) == .first else { return }
            Task { @MainActor in self?.onFirstFrame?() }
        }
        pipelineTask = Task.detached(priority: .userInitiated) { await pipeline.run() }
    }

    /// The tab hid: after this returns no frame reaches the presenter, even
    /// one whose decode was in flight, and nothing decodes until `start()`.
    /// The source sees the pause when the pipeline stops reading its access
    /// units (the stream terminates). The last frame stays on screen.
    public func pause() {
        delivery?.close()
        delivery = nil
        pipelineTask?.cancel()
        pipelineTask = nil
    }

    /// The session ended or the tab closed: `pause()` for good.
    public func stop() {
        ended = true
        pause()
        for continuation in sizeContinuations { continuation.finish() }
        sizeContinuations.removeAll()
    }

    /// Decoding now (started and not paused or stopped).
    public var isDecoding: Bool { pipelineTask != nil }

    /// The frame on screen, kept while the pane is paused: a hidden tab's picture.
    public var lastFrame: RemoteDecodedFrame? { presenter.shownFrame }

    private func frameSizeChanged(_ size: CGSize) {
        view.video.setFramePixels(size)
        for continuation in sizeContinuations { continuation.yield(size) }
    }
}
#endif
