public import AppKit
public import CmuxNextDesign
import CmuxNextCompat

// Every build: Release shows it only for a Cloud machine's desktop over its Native link; the
// development hosts stay Debug only (RemoteViewAvailability).
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
    /// A row of the toolbar's Quality menu: the App runs it as the palette's Set Screen Sharing
    /// Quality… (`remote.setQuality`, which calls ``RemoteDesktopPane/selectQuality(_:)``). Nil: the
    /// pane applies the row itself.
    public var pickQuality: ((RemoteQualityPreset) -> Void)?
    /// A display picked (phase 2: the host's display list).
    public var selectDisplay: (Int) -> Void = { _ in }
    /// The mode the toolbar asked for (the toggle, or Take over / Hand back), after the pane
    /// applied it: an owner whose session's mode is fixed at its start restarts it.
    public var selectMode: (RemoteControlMode) -> Void = { _ in }
    /// cmux shortcut matcher: true keeps the chord in the viewer.
    public var isLocalShortcut: (NSEvent) -> Bool = { _ in false }
    /// The person's input went to the host (control mode). Runs per event: keep it cheap.
    public var personInput: () -> Void = {}

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

    /// The release chord, as bound in KeyboardShortcutSettings.
    public var releaseChord: RemoteReleaseChord {
        get { view.capture.controller.releaseChord }
        set { view.capture.controller.releaseChord = newValue }
    }

    /// The session's state changed (an embedding view follows whether frames show).
    public var onStateChange: (() -> Void)?
    /// The remote pointer moved, in stream pixels.
    public var onCursor: ((RemoteCursorState?) -> Void)?
    /// A session is streaming and has shown a frame.
    public var isShowingFrames: Bool { state.hasFrame && state.overlay == nil }

    /// Upstream media commands (the transport); nil when the source has none.
    public var upstreamControl: (any RemoteUpstreamControl)?
    /// The macOS permission prompts, asked only from a share button press.
    public var upstreamPermissions: any RemoteUpstreamPermissions = SystemUpstreamPermissions()
    /// A permission prompt in flight per kind (one at a time per kind).
    private var permissionTasks: [RemoteUpstreamKind: Task<Void, Never>] = [:]

    public let presenterKind: RemotePresenterKind
    private let source: any RemoteViewStreamSource
    /// The input controller holds its sink weakly; the pane owns it.
    private let inputSink: (any RemoteViewInputSink)?
    private let presenter: any RemoteFramePresenter
    private var tasks: [Task<Void, Never>] = []
    private var pipeline: RemoteDecodePipeline?
    /// Armed while no frame was shown in this session; the first decoded
    /// frame consumes it and tells the reducer (`frameShown`).
    private let firstFrame = OneShotSignal()

    public init(
        hostName: String,
        source: any RemoteViewStreamSource,
        inputSink: (any RemoteViewInputSink)?,
        settings: RemoteDesktopSettings = RemoteDesktopSettings(),
        presenter: RemotePresenterKind = .metal,
        initialMode: RemoteControlMode = .control,
        scaling: RemoteViewGeometry.Scaling = .native,
        viaCloudTunnel: Bool = false,
        modeControl: RemoteModeControl = .toggle
    ) {
        self.source = source
        self.inputSink = inputSink
        self.settings = settings
        state = RemotePaneState(hostName: hostName, requestedMode: initialMode, interactiveMaxRttMs: settings.interactiveMaxRttMs)
        state.viaCloudTunnel = viaCloudTunnel
        state.modeControl = modeControl
        self.presenter = RemoteFramePresenters().make(presenter)
        presenterKind = self.presenter.kind
        view.video.install(self.presenter)
        view.video.scaling = scaling
        view.capture.controller.sink = inputSink
        view.capture.controller.onReleaseKeyboard = { [weak view] in view?.capture.releaseKeyboard() }
        view.capture.controller.onInput = { [weak self] in self?.handlers.personInput() }
        self.presenter.onFrameSize = { [weak self] size in
            self?.view.video.setFramePixels(size)
        }
        wireChrome()
        // The connect starts now: its card stays away for the short coming-up time.
        state = RemotePaneReducer().reduce(state, .connectNoticeCheck)
        armConnectNotice()
        view.render(state: state, settings: settings)
    }

    /// Starts decoding and following status. Idempotent.
    public func start() {
        guard tasks.isEmpty else { return }
        armConnectNotice() // a pane shown again mid-connect gets its deadline back (stop() cancels it)
        let presenter = self.presenter
        let firstFrame = self.firstFrame
        let deliver: @Sendable (RemoteDecodedFrame) -> Void = { [weak self] frame in
            presenter.present(frame)
            guard firstFrame.consume() else { return }
            Task { @MainActor in self?.apply(.frameShown) }
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
        tasks.append(Task { [weak self] in
            for await status in statuses { self?.apply(.status(status)) }
        })
        let cursors = source.cursorUpdates()
        tasks.append(Task { [weak self] in
            for await cursor in cursors {
                self?.view.cursor.setRemoteCursor(cursor)
                self?.onCursor?(cursor)
            }
        })
    }

    /// Stops decoding, releases held input and revokes every upstream kind
    /// (a hidden or closed tab never sends media). The last frame stays.
    public func stop() {
        stopAllUpstreams()
        for task in tasks { task.cancel() }
        tasks.removeAll()
        latencyCheck?.cancel()
        latencyCheck = nil
        latencyCheckDue = nil
        autoReconnectTask?.cancel()
        autoReconnectTask = nil
        connectNotice?.cancel()
        connectNotice = nil
        connectNoticeSince = nil
        pipeline = nil
        view.capture.controller.releaseAll()
    }

    /// Decode statistics of the running pipeline (debug surfaces, tests).
    public func decodeStats() async -> RemoteDecodePipeline.Stats? {
        await pipeline?.stats
    }

    /// The size of the last presented frame, in stream pixels (debug surfaces, tests).
    public var framePixels: CGSize { view.video.framePixels }

    /// Frames replaced before display by the latest-frame-wins presenter.
    public var discardedFrames: Int { presenter.discardedFrames }

    /// Applies one event through the reducer and re-renders.
    public func apply(_ event: RemotePaneEvent) {
        var next = RemotePaneReducer().reduce(state, event)
        // Not after an end the pane already shows (Stop, or the card past the last try): a late
        // lost-path status never reconnects against the person's Stop.
        if autoReconnectsLost, !state.isEnded, next.isEnded, case .ended(.connectionLost) = next.sessionState,
           state.hasFrame || state.reconnecting, autoReconnects < Self.autoReconnectBackoff.count {
            // A path that closed under a session that showed frames comes back by itself, over
            // the last frame and silently under the notice bound; Reconnect stays for the end.
            next = RemotePaneReducer().reduce(next, .reconnect)
            scheduleAutoReconnect()
        }
        // A session that shows its first frame came back: the next drop gets its own tries.
        if case .frameShown = event, next.hasFrame, !state.hasFrame || state.reconnecting { autoReconnects = 0 }
        // A frame that arrived before the session streamed did not count: wait for the next one.
        if !next.hasFrame { firstFrame.arm() }
        guard next != state else { return }
        state = next
        armLatencyCheck()
        armReconnectNotice()
        armConnectNotice()
        view.render(state: state, settings: settings)
        onStateChange?()
    }

    /// Whether a lost path reconnects by itself (the owner's `handlers.reconnect` starts the new
    /// session). Off: the ended card and its Reconnect button, as before.
    public var autoReconnectsLost = false
    /// Waits before each automatic reconnect of one drop: the first at once, then backing off;
    /// past the last the ended card shows (about 30 s of tries, plus each dial's own time).
    static let autoReconnectBackoff: [Duration] = [.zero, .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15)]
    /// Automatic reconnects since the last frame was shown.
    private(set) var autoReconnects = 0
    private var autoReconnectTask: Task<Void, Never>?

    private func scheduleAutoReconnect() {
        let delay = Self.autoReconnectBackoff[autoReconnects]
        autoReconnects += 1
        autoReconnectTask?.cancel()
        autoReconnectTask = Task { [weak self] in
            // wakeup-allow: one cancellable backoff step per lost path; Stop or a new session cancels it.
            if delay > .zero { do { try await Task.sleep(for: delay) } catch { return } }
            guard let self, !Task.isCancelled, state.sessionState == .connecting, state.reconnecting else { return }
            handlers.reconnect()
        }
    }

    /// The quiet reconnect's notice deadline, re-checked when it comes due.
    private var reconnectNotice: Task<Void, Never>?
    private var reconnectNoticeSince: ContinuousClock.Instant?

    private func armReconnectNotice() {
        let since = state.reconnectNoticeDue ? nil : state.reconnectingSince
        guard since != reconnectNoticeSince else { return }
        reconnectNotice?.cancel()
        reconnectNoticeSince = since
        guard let since else { return reconnectNotice = nil }
        reconnectNotice = Task { [weak self] in
            // wakeup-allow: one-shot notice deadline per reconnect; a frame or Stop cancels it.
            do { try await ContinuousClock().sleep(until: since + RemotePaneState.reconnectNoticeDelay, tolerance: .milliseconds(100)) } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            reconnectNoticeSince = nil
            apply(.reconnectNoticeCheck)
        }
    }

    /// The first connect's notice deadline (``RemotePaneState/connectNoticeDelay``), re-checked when it comes due.
    private var connectNotice: Task<Void, Never>?
    private var connectNoticeSince: ContinuousClock.Instant?

    private func armConnectNotice() {
        let since = state.connectNoticeDue ? nil : state.connectingSince
        guard since != connectNoticeSince else { return }
        connectNotice?.cancel()
        connectNoticeSince = since
        guard let since else { return connectNotice = nil }
        connectNotice = Task { [weak self] in
            // wakeup-allow: one-shot notice deadline per first connect; a frame, an end or Stop cancels it.
            do { try await ContinuousClock().sleep(until: since + RemotePaneState.connectNoticeDelay, tolerance: .milliseconds(50)) } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            connectNoticeSince = nil
            apply(.connectNoticeCheck)
        }
    }

    /// The latency hold's flip, re-checked when it comes due if no sample comes first.
    private var latencyCheck: Task<Void, Never>?
    private var latencyCheckDue: ContinuousClock.Instant?

    private func armLatencyCheck() {
        let due = state.latency.due
        guard due != latencyCheckDue else { return }
        latencyCheck?.cancel()
        latencyCheckDue = due
        guard let due else { return latencyCheck = nil }
        // A bounded, cancellable one-shot: the next sample or a settled hold cancels it.
        latencyCheck = Task { [weak self] in
            // wakeup-allow: one-shot latency hold deadline; the next sample cancels it.
            do { try await ContinuousClock().sleep(until: due, tolerance: .milliseconds(100)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            latencyCheckDue = nil
            apply(.latencyCheck)
        }
    }

    private func wireChrome() {
        view.toolbar.onSelectMode = { [weak self] mode in self?.selectMode(mode) }
        view.toolbar.onSelectQuality = { [weak self] preset in
            guard let self else { return }
            if let pick = handlers.pickQuality { return pick(preset) }
            selectQuality(preset)
        }
        view.toolbar.onSelectDisplay = { [weak self] in self?.handlers.selectDisplay($0) }
        view.toolbar.onStop = { [weak self] in self?.stopPressed() }
        view.toolbar.onUpstream = { [weak self] in self?.upstreamPressed($0) }
        view.upstreamIndicator.onStop = { [weak self] in self?.stopUpstream($0) }
        view.card.onCancel = { [weak self] in self?.stopPressed() }
        view.card.onReconnect = { [weak self] in
            // The person asked again: a drop after this gets its own automatic tries.
            self?.autoReconnects = 0
            self?.apply(.reconnect)
            self?.handlers.reconnect()
        }
        view.card.onClose = { [weak self] in self?.handlers.close() }
        view.banner.onControlAnyway = { [weak self] in self?.apply(.controlAnyway) }
    }

    /// A quality preset for this session (the Quality menu's row, `remote.setQuality`): the toolbar
    /// shows it, then the owner is told.
    public func selectQuality(_ preset: RemoteQualityPreset) {
        settings.quality = preset
        view.render(state: state, settings: settings)
        handlers.selectQuality(preset)
    }

    /// Why Set Screen Sharing Quality… cannot run: no remote desktop session is shown.
    public static var noSessionReason: String { RemoteViewStrings.unavailableTitle }

    /// The toolbar's mode choice: applied, then told to the owner (a press of the mode already
    /// in force does nothing).
    public func selectMode(_ mode: RemoteControlMode) {
        guard mode != state.requestedMode else { return }
        apply(.selectMode(mode))
        handlers.selectMode(mode)
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
    // carve-out: `consume()` answers synchronously on the capture thread; an actor would make it async.
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
