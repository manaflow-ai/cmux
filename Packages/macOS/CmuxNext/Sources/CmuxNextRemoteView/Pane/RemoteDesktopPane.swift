public import AppKit
public import CmuxNextDesign
public import CmuxNextWakeups
import CmuxNextCompat

// Development builds only: the pane is not exposed in Release until the
// overlay link token authenticates hello claims (RemoteViewAvailability).
#if DEBUG
/// What the pane asks of its owner (the App: transport, layout, settings).
public struct RemoteDesktopPaneHandlers {
    /// Stop pressed (toolbar, or Cancel while connecting): close the session.
    public var stop: () -> Void = {}
    /// Reconnect pressed on an ended session: start a new one on the same source.
    public var reconnect: () -> Void = {}
    /// Close pressed on an ended session: close the tab.
    public var close: () -> Void = {}
    /// A quality preset picked in the toolbar menu (`remoteDesktop.quality`
    /// for this session; the App sends it to the host).
    public var selectQuality: (RemoteQualityPreset) -> Void = { _ in }
    /// A display picked (phase 2: the host's display list).
    public var selectDisplay: (Int) -> Void = { _ in }
    /// cmux shortcut matcher: true keeps the chord in the viewer.
    public var isLocalShortcut: (NSEvent) -> Bool = { _ in false }

    public init() {}
}

/// One remote desktop pane: owns the state (`RemotePaneReducer` is its only
/// writer), the decode pipeline, the presenter and the view. The App
/// creates one per `remote_view` tab, supplies the source and sink, and
/// calls `start()` while the pane is visible and `stop()` when it hides
/// (a hidden pane pauses the stream; section 2.3).
@MainActor
public final class RemoteDesktopPane {
    public let view = RemoteDesktopPaneView()
    public private(set) var state: RemotePaneState
    public var settings: RemoteDesktopSettings {
        didSet {
            state = RemotePaneReducer().reduce(state, .setInteractiveMaxRtt(settings.interactiveMaxRttMs))
            view.render(state: state, settings: settings)
        }
    }

    public var handlers = RemoteDesktopPaneHandlers() {
        didSet { view.capture.controller.isLocalShortcut = handlers.isLocalShortcut }
    }

    /// The windows' frame-aligned pointer input (feature `pointerFrameRemoteInput`): moves, drags and
    /// mid-gesture scrolls reach the host at most twice per display frame. Nil sends each at once.
    public var pointerFrames: FrameInputCoalescers? {
        get { view.capture.pointerFrames }
        set { view.capture.pointerFrames = newValue }
    }

    /// The release chord, as bound in KeyboardShortcutSettings.
    public var releaseChord: RemoteReleaseChord {
        get { view.capture.controller.releaseChord }
        set { view.capture.controller.releaseChord = newValue }
    }

    /// Upstream media commands (the transport); nil when the source has none.
    public var upstreamControl: (any RemoteUpstreamControl)?
    /// The macOS permission prompts, asked only from a share button press.
    public var upstreamPermissions: any RemoteUpstreamPermissions = SystemUpstreamPermissions()
    /// A permission prompt in flight per kind (one at a time per kind).
    private var permissionTasks: [RemoteUpstreamKind: Task<Void, Never>] = [:]

    public let presenterKind: RemotePresenterKind
    /// The app's main-thread scheduler: frames, the first frame's state change, status and cursor apply in its
    /// visible class (the remote screen's own updates).
    private let mainWork: MainWorkScheduler
    private let source: any RemoteViewStreamSource
    /// The input controller holds its sink weakly; the pane owns it.
    private let inputSink: (any RemoteViewInputSink)?
    private let presenter: any RemoteFramePresenter
    private var tasks: [Task<Void, Never>] = []
    private var pipeline: RemoteDecodePipeline?
    /// The running session's frame gate: closed at `stop()`, so a hidden pane presents nothing.
    private var delivery: RemoteFrameGate?
    /// Runs once per started session when the pane shows its own content: the first frame went on
    /// screen, or the session ended before one did (the card says why). A woken tab's last frame
    /// then goes (`BrowserWakeCover`).
    public var onOwnContent: (() -> Void)?
    private var awaitsOwnContent = false
    /// Armed while no frame was shown in this session; the first decoded
    /// frame consumes it and tells the reducer (`frameShown`).
    private let firstFrame = OneShotSignal()

    public init(
        hostName: String,
        source: any RemoteViewStreamSource,
        inputSink: (any RemoteViewInputSink)?,
        mainWork: MainWorkScheduler,
        settings: RemoteDesktopSettings = RemoteDesktopSettings(),
        presenter: RemotePresenterKind = RemoteViewTunables().presenter.value,
        initialMode: RemoteControlMode = .control,
        scaling: RemoteViewGeometry.Scaling = .native,
        viaCloudTunnel: Bool = false
    ) {
        self.source = source
        self.inputSink = inputSink
        self.mainWork = mainWork
        self.settings = settings
        state = RemotePaneState(hostName: hostName, requestedMode: initialMode, interactiveMaxRttMs: settings.interactiveMaxRttMs)
        state.viaCloudTunnel = viaCloudTunnel
        self.presenter = RemoteFramePresenters().make(presenter, mainWork: mainWork)
        presenterKind = self.presenter.kind
        view.video.install(self.presenter)
        view.video.scaling = scaling
        view.capture.controller.sink = inputSink
        view.capture.controller.onReleaseKeyboard = { [weak view] in view?.capture.releaseKeyboard() }
        self.presenter.onFrameSize = { [weak self] size in
            self?.view.video.setFramePixels(size)
        }
        self.presenter.onFrameShown = { [weak self] in self?.frameShown() }
        wireChrome()
        view.render(state: state, settings: settings)
    }

    /// Starts decoding and following status. Idempotent.
    public func start() {
        guard tasks.isEmpty else { return }
        let presenter = self.presenter
        let firstFrame = self.firstFrame
        let gate = RemoteFrameGate()
        delivery = gate
        awaitsOwnContent = true
        let work = mainWork
        let owner = work.board.owner("remote-view.session")
        // One visible task per change, in arrival order (one class queue is FIFO); a task of a stopped session (its
        // gate is no longer the pane's) does nothing.
        let post: @Sendable (@escaping @MainActor @Sendable (RemoteDesktopPane) -> Void) -> Void = { [weak self] change in
            // node-free: the gate closes at stop(), when the pane hides; a stopped session's late change is dropped.
            work.postFromAnyThread(.visible, owner: owner) { [weak self] in
                guard let self, delivery === gate else { return }
                change(self)
            }
        }
        let deliver: @Sendable (RemoteDecodedFrame) -> Void = { frame in
            guard gate.deliver(frame, to: presenter), firstFrame.consume() else { return }
            post { $0.apply(.frameShown) }
        }
        if let frameSource = source as? any RemoteViewFrameSource {
            let frames = frameSource.decodedFrames()
            tasks.append(Task.detached(priority: .userInitiated) {
                for await frame in frames { deliver(frame) }
            })
        } else {
            let pipeline = RemoteDecodePipeline(source: source, deliver: deliver)
            self.pipeline = pipeline
            tasks.append(Task.detached(priority: .userInitiated) { await pipeline.run() })
        }
        let statuses = source.statusUpdates()
        // task-owner: the session's status, read off main; ends at stop() or when the source finishes it.
        tasks.append(Task { @concurrent in
            for await status in statuses { post { $0.apply(.status(status)) } }
        })
        let cursors = source.cursorUpdates()
        // task-owner: the remote cursor, read off main; ends at stop() or when the source finishes it.
        tasks.append(Task { @concurrent in
            for await cursor in cursors { post { $0.view.video.setRemoteCursor(cursor) } }
        })
    }

    /// Stops decoding, releases held input and revokes every upstream kind
    /// (a hidden or closed tab never sends media). The last frame stays.
    public func stop() {
        stopAllUpstreams()
        delivery?.close()
        delivery = nil
        for task in tasks { task.cancel() }
        tasks.removeAll()
        pipeline = nil
        view.capture.controller.releaseAll()
    }

    /// Decode statistics of the running pipeline (debug surfaces, tests).
    public func decodeStats() async -> RemoteDecodePipeline.Stats? {
        await pipeline?.stats
    }

    /// The size of the last presented frame, in stream pixels (debug surfaces, tests).
    public var framePixels: CGSize { view.video.framePixels }

    /// The frame on screen, kept while the pane is stopped.
    public var lastFrame: RemoteDecodedFrame? { presenter.shownFrame }

    /// The pane as drawn with its last frame in the video (a hidden tab's picture); nil before
    /// the first frame, or while the pane shows a card over it (then `cacheDisplay` draws it all).
    public func picture() async -> CGImage? {
        guard let frame = lastFrame, state.overlay == nil, let image = await frame.picture() else { return nil }
        return view.video.composite(image, in: view)
    }

    private func frameShown() {
        guard awaitsOwnContent else { return }
        awaitsOwnContent = false
        onOwnContent?()
    }

    /// Frames replaced before display by the latest-frame-wins presenter.
    public var discardedFrames: Int { presenter.discardedFrames }

    /// Applies one event through the reducer and re-renders.
    public func apply(_ event: RemotePaneEvent) {
        let next = RemotePaneReducer().reduce(state, event)
        // A frame that arrived before the session streamed did not count: wait for the next one.
        if !next.hasFrame { firstFrame.arm() }
        guard next != state else { return }
        state = next
        view.render(state: state, settings: settings)
        // The card says why the session ended: the pane shows its own content.
        if next.isEnded { frameShown() }
    }

    private func wireChrome() {
        view.toolbar.onSelectMode = { [weak self] in self?.apply(.selectMode($0)) }
        view.toolbar.onSelectQuality = { [weak self] preset in
            guard let self else { return }
            settings.quality = preset
            view.render(state: state, settings: settings)
            handlers.selectQuality(preset)
        }
        view.toolbar.onSelectDisplay = { [weak self] in self?.handlers.selectDisplay($0) }
        view.toolbar.onStop = { [weak self] in self?.stopPressed() }
        view.toolbar.onUpstream = { [weak self] in self?.upstreamPressed($0) }
        view.upstreamIndicator.onStop = { [weak self] in self?.stopUpstream($0) }
        view.card.onCancel = { [weak self] in self?.stopPressed() }
        view.card.onReconnect = { [weak self] in
            self?.apply(.reconnect)
            self?.handlers.reconnect()
        }
        view.card.onClose = { [weak self] in self?.handlers.close() }
        view.banner.onControlAnyway = { [weak self] in self?.apply(.controlAnyway) }
    }

    /// A share button: the user's explicit action for `kind`. It asks macOS
    /// for the permission, then the transport opens the stream (a denied
    /// permission sends nothing). Pressing an active kind stops it.
    func upstreamPressed(_ kind: RemoteUpstreamKind) {
        let upstream = state.upstream
        if upstream.active.contains(kind) || upstream.requested.contains(kind) {
            stopUpstream(kind)
            return
        }
        guard state.showsUpstreamButtons, permissionTasks[kind] == nil, let control = upstreamControl else { return }
        let permissions = upstreamPermissions
        // main-hop-allow: the person's share press: request is the main-actor async macOS permission prompt (it waits on the person); the task only holds its answer and sends it
        permissionTasks[kind] = Task { [weak self] in
            let granted = await permissions.request(kind)
            guard let self else { return }
            permissionTasks[kind] = nil
            // The tab hid or the session ended while the prompt was open.
            guard !Task.isCancelled, state.showsUpstreamButtons else { return }
            control.requestUpstream(kind, permissionGranted: granted)
        }
    }

    /// The indicator's Stop: hides the kind and revokes its consent at once.
    func stopUpstream(_ kind: RemoteUpstreamKind) {
        permissionTasks.removeValue(forKey: kind)?.cancel()
        apply(.stopUpstream(kind))
        upstreamControl?.stopUpstream(kind)
    }

    private func stopAllUpstreams() {
        for task in permissionTasks.values { task.cancel() }
        permissionTasks.removeAll()
        apply(.stopAllUpstreams)
        upstreamControl?.stopAllUpstreams()
    }

    private func stopPressed() {
        stopAllUpstreams()
        apply(.stop)
        view.capture.controller.releaseAll()
        handlers.stop()
    }
}

/// A flag one thread arms and another consumes once.
nonisolated final class OneShotSignal: Sendable {
    private let armed = Mutex(true)

    func arm() { armed.withLock { $0 = true } }

    /// True once per arm.
    func consume() -> Bool {
        armed.withLock { value in
            defer { value = false }
            return value
        }
    }
}
#endif
