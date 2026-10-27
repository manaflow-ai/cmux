public import AppKit
public import CmuxNextRemoteView
import CmuxNextCompat
public import CmuxNextWakeups

#if DEBUG || CMUX_BENCH_HOOKS
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
    /// Runs when a started pipeline's first frame went on screen (a woken tab's picture then goes,
    /// `BrowserWakeCover`).
    public var onFirstFrame: (() -> Void)?
    private var awaitsFirstFrame = false

    /// `mainWork` is the app's scheduler: the presenter shows frames in its visible class.
    public convenience init(source: any RemoteViewStreamSource, mainWork: MainWorkScheduler, presenter: RemotePresenterKind = .layerContents) {
        self.init(source: source, presenter: RemoteFramePresenters().make(presenter, mainWork: mainWork))
    }

    /// `presenter` receives every decoded frame (tests pass a recorder).
    package init(source: any RemoteViewStreamSource, presenter: any RemoteFramePresenter) {
        self.source = source
        self.presenter = presenter
        view.video.install(self.presenter)
        self.presenter.onFrameSize = { [weak self] size in self?.frameSizeChanged(size) }
        self.presenter.onFrameShown = { [weak self] in self?.frameShown() }
    }

    /// Decodes and presents the source's frames. Idempotent; nothing after `stop()`. A new
    /// pipeline subscribes again and waits for a keyframe, which it asks the source for.
    public func start() {
        guard pipelineTask == nil, !ended else { return }
        let presenter = self.presenter
        let gate = RemoteFrameGate()
        delivery = gate
        awaitsFirstFrame = true
        let pipeline = RemoteDecodePipeline(source: source) { frame in _ = gate.deliver(frame, to: presenter) }
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

    /// The frame on screen, kept while the pane is paused.
    public var lastFrame: RemoteDecodedFrame? { presenter.shownFrame }

    /// The page as drawn with its last frame in the video (a hidden tab's picture); nil before the
    /// first frame, or while the page shows why it failed (then `cacheDisplay` draws it all).
    public func picture() async -> CGImage? {
        guard let frame = lastFrame, view.failureMessage == nil, let image = await frame.picture() else { return nil }
        return view.video.composite(image, in: view)
    }

    private func frameShown() {
        guard awaitsFirstFrame else { return }
        awaitsFirstFrame = false
        onFirstFrame?()
    }

    private func frameSizeChanged(_ size: CGSize) {
        view.video.setFramePixels(size)
        for continuation in sizeContinuations { continuation.yield(size) }
    }
}
#endif
