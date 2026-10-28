import Foundation
import CmuxNextWakeups
import GhosttyNextKit

/// Per-surface userdata handed to Ghostty as `userdata`, `io_write_userdata`,
/// with renderer-owned frames `presented_userdata`, on external vsync
/// `vsync_userdata`, and with an external cursor `cursor_userdata` (ghostty.h).
///
/// Retained for the surface's lifetime and released only after
/// `ghostty_surface_free` returns, because free joins the IO thread that may
/// still be inside `io_write_cb` and waits for a running `presented_cb`.
///
/// Checked Sendable: Ghostty's IO, renderer and Core Animation threads read only the
/// immutable `input`, `linkFilter`, `frames`, `frameMarks`, `keySlots`, `vsync` (itself
/// Sendable) and `cursor`, and an input lock wait report only the immutable `lockWait`;
/// everything mutable is main-actor isolated.
nonisolated final class SurfaceBridge: Sendable {
    let input: TerminalInputSink
    /// What the surface's callbacks reach: its view in the app, a test's recorder. Main-actor only.
    /// Weak so a late callback after the view deinitializes is a no-op.
    @MainActor weak var target: (any GhosttySurfaceTarget)?
    /// The view that shows the surface (``target`` in the app).
    @MainActor var view: TerminalSurfaceView? { target as? TerminalSurfaceView }
    /// The font scale after each font size change (nil: the configured
    /// size), `TerminalFontScale.observe`.
    @MainActor var onFontScaleChange: (@MainActor @Sendable (Double?) -> Void)?
    /// The last font scale Ghostty reported, nil at the configured size.
    @MainActor var fontScale: Double?
    /// True once Ghostty reported any font size change (a zoom, a reset or a set).
    @MainActor var fontScaleChanged = false
    /// The surface's state actions waiting for its window's frame (``actionMailbox``); made with the first.
    @MainActor private var mailbox: GhosttyActionMailbox?

    /// The cached answers to Ghostty's link filter (cx-do47.1).
    let linkFilter = TerminalLinkFilter()
    /// What the Ghostty trace hook marks for this surface's frames (``GhosttyTraceHook``).
    let frames: GhosttyTraceHook.Surface
    /// The hook ``frames`` are registered with and the surface's trace id; nil while not registered.
    @MainActor private var traceRegistration: (hook: GhosttyTraceHook, id: UInt64)?
    /// Where this surface's presented frames are marked (``ghosttySurfacePresented(_:_:_:_:)``); nil: nowhere.
    let frameMarks: GhosttyTraceHook.Recorder?
    /// Names the key press the app is dispatching, whose bytes carry its flow (``dispatchingKeyFlow``); nil: none.
    let keySlots: TerminalEchoStages?
    /// Paces the surface from its display's ``VSyncHub`` thread on external vsync (``TerminalVSync``). Owned here
    /// so it lives exactly as long as the `vsync_userdata` Ghostty holds, past `ghostty_surface_free`.
    let vsync = TerminalVSync()
    /// Where Ghostty's present puts the surface's cursor cell (``ghosttySurfaceCursor(_:_:)``); nil: Ghostty draws
    /// the cursor.
    let cursor: TerminalCursorPresenter?
    /// Where the surface's input waits for Ghostty's terminal lock go (``GhosttyLockWaitSignpost``): one handle
    /// for the surface's life, so a report builds nothing.
    let lockWait = GhosttyLockWaitSignpost()

    init(input: TerminalInputSink, echoStage: TerminalEchoStage? = nil, frameMarks: GhosttyTraceHook.Recorder? = nil,
         keySlots: TerminalEchoStages? = nil, cursor: TerminalCursorPresenter? = nil) {
        self.input = input
        self.frameMarks = frameMarks
        self.keySlots = keySlots
        self.cursor = cursor
        frames = GhosttyTraceHook.Surface(key: input.typingSurface, echoStage: echoStage)
    }

    /// A link answer that changed (on the filter's queue) shows in the next main turn: the pointer goes to
    /// Ghostty again, as one `userBlocking` task on `mainWork`, the rest of the person's Command-hover.
    @MainActor func followLinkAnswers(on mainWork: MainWorkScheduler) {
        let owner = mainWork.board.owner("terminal.link-answer")
        linkFilter.onChange { [weak self] in
            mainWork.postFromAnyThread(.userBlocking, owner: owner) { self?.sendPointerAgain() }
        }
    }

    /// Registers ``frames`` with `hook` under `surface`'s trace id, right after `ghostty_surface_new`.
    @MainActor func traceFrames(of surface: ghostty_surface_t, with hook: GhosttyTraceHook?) {
        guard let hook else { return }
        // SAFETY: the caller's live surface, just made (TerminalSurfaceView.createSurface); only its id is read.
        let id = unsafe hook.register(frames, of: surface)
        if id != 0 { traceRegistration = (hook, id) }
    }

    /// After `ghostty_surface_free` returned and before this bridge's release: the hook stops reading the
    /// surface's calls while ``frames`` is still alive.
    @MainActor func surfaceFreed() {
        guard let traceRegistration else { return }
        traceRegistration.hook.unregister(id: traceRegistration.id)
        self.traceRegistration = nil
    }

    /// The session's surfaces to the typing probe (``TypingLatencyProbe``): the key router opens a press
    /// on it, and Ghostty's writes, the output lane and the frame mark by it.
    var typingSurface: TypingLatencyProbe.SurfaceKey { input.typingSurface }

    /// The latency slot flow of the key press whose dispatch makes Ghostty write now (0: none): Ghostty writes a
    /// key's bytes inline on the main thread, inside its dispatch; a write on its IO thread is no key's.
    var dispatchingKeyFlow: UInt64 {
        guard let keySlots, Thread.isMainThread else { return 0 }
        return MainActor.assumeIsolated { keySlots.dispatchingKeyFlow } // main-proof: guarded by Thread.isMainThread above
    }

    /// Ghostty wrote `bytes` (`io_write_cb`, on the thread that made the write): one on the main thread
    /// (a key, a paste, a report) reaches the session's echo predictions (``PredictiveEchoSlot/written(_:by:)``).
    func wrote(_ bytes: Data) {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated { // main-proof: guarded by Thread.isMainThread above
            guard let view else { return }
            input.predictions.written(bytes, by: view)
        }
    }

    /// The surface's ``GhosttyActionMailbox``: its state actions apply once per frame of its target's
    /// window, to the target that shows it then; while nobody sees the target's tab they wait for it to show.
    @MainActor var actionMailbox: GhosttyActionMailbox {
        if let mailbox { return mailbox }
        let made = GhosttyActionMailbox(owner: "terminal.actions", scheduler: { [weak self] in
            self?.target?.actionFrameScheduler ?? .app
        }, node: { [weak self] in
            self?.target?.actionNode
        }, apply: { [weak self] action in
            _ = self?.target?.applyAction(action)
        })
        mailbox = made
        return made
    }

    /// Applies the surface's waiting state actions now: a discrete action, clipboard request or close
    /// of this surface runs after them, in the order Ghostty sent them.
    @MainActor func flushActions() {
        mailbox?.flush()
    }

    /// One of the surface's Ghostty actions (`action_cb`): a state action waits in its mailbox for the
    /// frame (reported performed); any other runs now, after the waiting state, and reports what it did
    /// (a keybind that did nothing falls through to the terminal).
    @MainActor func deliver(_ action: GhosttyAction, runtime: GhosttyRuntime?) -> Bool {
        if let slot = action.mailboxSlot {
            actionMailbox.post(action, in: slot)
            return true
        }
        if action.flushesMailbox { flushActions() }
        return GhosttyActionDispatcher.dispatch(action, bridge: self, runtime: runtime)
    }

    /// Ghostty asks for consent to a paste or a clipboard read or write (`confirm_read_clipboard_cb`),
    /// after the state it sent before.
    @MainActor func confirmClipboard(contents: String, contentBytes: Int, kind: TerminalClipboardRequestKind, state: UncheckedPointer) {
        flushActions()
        target?.confirmClipboard(contents: contents, contentBytes: contentBytes, kind: kind, state: state)
    }

    /// Ghostty writes the clipboard (`write_clipboard_cb`), after the state it sent before.
    @MainActor func writeClipboard(items: [TerminalClipboardItem], location: TerminalPasteboardLocation, requiresConfirmation: Bool) {
        flushActions()
        target?.writeClipboard(items: items, location: location, requiresConfirmation: requiresConfirmation)
    }

    /// The surface's program asked to close it (`close_surface_cb`), after the state it sent before.
    @MainActor func requestClose() {
        flushActions()
        target?.surfaceRequestedClose()
    }

    /// Sets the surface's callbacks in `config`: its writes (``ghosttyIOWrite(_:_:_:)``) and, with renderer-owned
    /// frames (`GHOSTTY_RENDERER_FRAMES`), the renderer's presentations off main, each the surface's frame mark
    /// (``ghosttySurfacePresented(_:_:_:_:)``). `userdata` is the surface's bridge, released only after
    /// `ghostty_surface_free` returns, after which Ghostty starts no call.
    static func setCallbacks(in config: inout ghostty_surface_config_s, userdata: UnsafeMutableRawPointer) {
        // SAFETY: the callback has ghostty_io_write_cb's signature; `userdata` as above.
        unsafe config.io_write_cb = ghosttyIOWrite
        // SAFETY: as above.
        unsafe config.io_write_userdata = userdata
        #if GHOSTTY_RENDERER_FRAMES
        // SAFETY: the callback has ghostty_surface_presented_cb's signature; `userdata` as above.
        unsafe config.presented_cb = ghosttySurfacePresented
        // SAFETY: as above.
        unsafe config.presented_userdata = userdata
        #endif
    }

    /// Turns external vsync on in `config` (ghostty-next p03-rendering-082): the surface makes no display link,
    /// and its wanted edges reach ``vsync`` through ``ghosttySurfaceVSyncWanted(_:_:)``. `userdata` is the
    /// surface's bridge, as in ``setCallbacks(in:userdata:)``. Without the export (`GHOSTTY_EXTERNAL_VSYNC` off)
    /// the config is left as it is.
    static func setExternalVSync(in config: inout ghostty_surface_config_s, userdata: UnsafeMutableRawPointer) {
        #if GHOSTTY_EXTERNAL_VSYNC
        config.vsync_external = true
        // SAFETY: the callback has ghostty_surface_vsync_wanted_cb's signature; `userdata` as above.
        unsafe config.vsync_wanted_cb = ghosttySurfaceVSyncWanted
        // SAFETY: as above.
        unsafe config.vsync_userdata = userdata
        #endif
    }

    /// `raw` must be a surface's userdata (TerminalSurfaceView.bridge) or nil.
    static func from(_ raw: UnsafeMutableRawPointer?) -> SurfaceBridge? {
        // SAFETY: the caller passes the bridge the view retained for its surface, which stays
        // alive until after ghostty_surface_free returns (TerminalSurfaceView.deinit), so every
        // callback that brings it back sees a live object; taken unretained, as it was passed.
        guard let raw = unsafe raw else { return nil }
        // SAFETY: as above.
        return unsafe Unmanaged<SurfaceBridge>.fromOpaque(raw).takeUnretainedValue()
    }
}

/// Ordered hand-off from Ghostty's `io_write_cb` (and the session's grid, focus and reconnect
/// requests) to the session's ``TerminalIO``. One ``TerminalInputLane`` per session, shared by every
/// surface the session swaps in, so input order survives a surface swap.
nonisolated struct TerminalInputSink: Sendable {
    private let lane: TerminalInputLane
    /// The session's surfaces to the typing probe (``TypingLatencyProbe``): the same across a surface
    /// swap, like the input order.
    let typingSurface: TypingLatencyProbe.SurfaceKey
    /// The session's echo predictions, shared by its surfaces like the input order (``PredictiveEchoSlot``).
    let predictions = PredictiveEchoSlot()

    init(lane: TerminalInputLane, typingSurface: TypingLatencyProbe.SurfaceKey) {
        self.lane = lane
        self.typingSurface = typingSurface
    }

    /// Sends `data`; `keyFlow` is the latency slot flow of the key press it encodes (0: none).
    func send(_ data: Data, keyFlow: UInt64 = 0) {
        lane.push(keyFlow == 0 ? .bytes(data) : .keyBytes(data, keyFlow: keyFlow))
    }

    func resize(_ grid: TerminalGridSize, pixelWidth: Int, pixelHeight: Int) {
        lane.push(.resize(grid, pixelWidth: pixelWidth, pixelHeight: pixelHeight))
    }

    func reconnect() {
        lane.push(.reconnect)
    }

    func resync() {
        lane.push(.resync)
    }

    func focusGained() {
        lane.push(.focusGained)
    }

    func takeOverSize(setLatest: Bool) {
        lane.push(.takeOverSize(setLatest: setLatest))
    }

    /// Drops later input; what was pushed before still reaches the IO.
    func finish() {
        lane.close()
    }
}

/// `io_write_cb`: runs on the thread that made the write (the main thread for keys and pastes, which
/// Ghostty's manual backend writes inline; its IO thread otherwise). Copies the bytes and hands them
/// to the session's input lane (``TerminalInputLane``).
nonisolated func ghosttyIOWrite(_ userdata: UnsafeMutableRawPointer?, _ bytes: UnsafePointer<CChar>?, _ length: UInt) {
    // SAFETY: a surface's userdata (SurfaceBridge.from); Ghostty passes `length` bytes, valid for
    // this callback, which Data copies.
    guard let bridge = unsafe SurfaceBridge.from(userdata), let bytes = unsafe bytes, length > 0 else { return }
    TypingLatencyProbe.shared.inputWritten(on: bridge.input.typingSurface)
    // SAFETY: as above.
    let data = unsafe Data(bytes: bytes, count: Int(length))
    bridge.wrote(data)
    bridge.input.send(data, keyFlow: bridge.dispatchingKeyFlow)
}
