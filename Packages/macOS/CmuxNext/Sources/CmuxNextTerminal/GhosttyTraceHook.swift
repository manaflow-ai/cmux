public import CmuxNextDesign
public import CmuxNextSignposts
import CmuxNextTrace
public import CmuxNextWakeups
import GhosttyNextKit

/// cmux's end of ghostty-next's trace hook: the renderer's own frames in the
/// app's trace ring and the frame marks of its key echoes, in Release builds too.
///
/// Ghostty keeps one process-wide pointer to an embedder-owned record `{callback, ctx}`
/// (`ghostty_set_trace_hook`, ghostty.h), as Chromium's embedders get a renderer's frame timing through a
/// callback they register (base/trace_event/trace_log.h, `TraceLog::SetAddTraceEventOverrides`), not by
/// patching the renderer. Each call names its surface by `ghostty_surface_trace_id` (nonzero, never reused),
/// never by a pointer, and the hook finds that surface's state in its ``SurfaceTable``: an id it does not
/// track (a surface made before registration, a present queued before `ghostty_surface_free` that lands
/// after it) is ignored. It records:
/// - `ghostty.render` (B/E on the drawing thread) around each draw, arg0 the surface's
///   ``TypingLatencyProbe/SurfaceKey/traceID``, begin arg1 the flow of the press whose echo it draws (0: none),
///   so a STRESS trace shows it between `app.output.parsed` and `frame.commit`;
/// - `frame.gpu_done` (instant) from the frame's Metal completion handler, arg0 the surface, arg1 its seq;
/// - the first `CONTENTS_SET` of each frame: the surface's ``TerminalEchoStage/contentsSet()`` while the
///   contents gate is open, and the probe's ``TypingLatencyProbe/Mark/contents`` for the surface's parsed
///   presses (key.echo_frame's sample end). Once the app gave the hook its presents
///   (``connect(on:presents:)``), a frame handed over before its GPU work ended marks its commit
///   `awaitsGPU`, and its completion posts those flows to ``FramePresentEstimate/gpuDidFinish(flow:atNanos:)``.
///
/// The record is installed only while something reads it (``refreshDemand()``): an echo stage sink, the
/// typing probe's recording or its `key.echo_frame` sampling (``TypingLatencyProbe/samplesEchoFrames``, which
/// the first ``refreshDemand()`` turns on, so the record stays installed and a handoff between samples pays one
/// load), or the `ghostty` or `frame` trace category, followed from their observers (``followDemand(post:)``);
/// otherwise Ghostty's pointer is null and each event site pays one load. Whether the linked libghostty has the
/// hook is fixed when the app is built: the `GHOSTTY_TRACE_HOOK` condition (`ghosttyNextKitCapabilities` in
/// Package.swift) comes with the GhosttyNextKit pin that exports it, and the hook calls the C declarations
/// directly, so the compiler checks their signatures and the link keeps them.
///
/// With renderer-owned frames (`GHOSTTY_RENDERER_FRAMES`, ghostty-next p03-rendering-080) the renderer presents
/// each frame itself off the main thread, so the frame mark is its presentation: each surface's
/// `presented_cb` (``ghosttySurfacePresented(_:_:_:_:)``) marks the echo stage, the probe's
/// ``TypingLatencyProbe/Mark/contents`` and the new-terminal trace, as Chromium marks a frame shown at its
/// presentation feedback (`viz::Display::DidReceivePresentationFeedback`, components/viz/service/display/display.cc).
/// The handoff then marks nothing, so no frame counts twice and no frame counts before it shows. Each shown frame
/// is also a contents set of ``TerminalSurfaceView`` in the app's ``RenderStats`` (``countPresentedFrames(in:)``),
/// which no `setContents:` hook sees once the renderer presents.
@MainActor
public final class GhosttyTraceHook {
    /// Installs (`true`) or removes (`false`) this hook's record in libghostty: `ghostty_set_trace_hook`.
    typealias Setter = @MainActor (_ installed: Bool) -> Void

    /// Where the hook's record goes.
    enum Linkage {
        /// The pinned GhosttyNextKit's `ghostty_set_trace_hook`; unsupported when the pin has none.
        case libghostty
        /// A test's stand-in for `ghostty_set_trace_hook`.
        case custom(Setter)
        /// No hook: the build sees no Ghostty frames through it.
        case unsupported
    }

    /// `ghostty_trace_event_e` (ghostty.h), with its values: what a hook call marks.
    nonisolated enum Event: UInt32, Sendable {
        /// A draw starts; seq: the number its frame gets if it commits one.
        case frameBegin = 0
        /// The draw ends; seq: the frame it committed, 0 when none.
        case frameEnd = 1
        /// A frame's IOSurface became its layer's contents; seq: the frame. One frame can come twice.
        case contentsSet = 2
        /// The GPU completed a frame; seq: the frame.
        case gpuDone = 3
        /// Ghostty passed encoded input to `io_write_cb`; seq: the byte count.
        case ioWrite = 4
        /// `ghostty_surface_free` returned; seq: 0.
        case surfaceDestroy = 5
    }

    /// What every hook call reads, from any thread.
    let recorder: Recorder
    /// The recorder as the record's `ctx`: retained once for the process, since a call already past Ghostty's
    /// load of the record may still run after the hook is removed.
    /// SAFETY: the retain in `init` is never released, so the address stays a live Recorder for every hook call.
    @safe let context: UnsafeMutableRawPointer
    private let setter: Setter?
    /// Whether the record is installed now.
    public private(set) var isInstalled = false
    /// An echo stage sink is installed (``TerminalEchoStages/install(_:)``): its stages need the handoffs.
    private var echoStagesNeedFrames = false

    /// - Parameters:
    ///   - gate: The process's contents gate (``TerminalEchoStages/contentsGate``).
    ///   - trace: The runtime the records go to.
    ///   - probe: The typing probe the handoffs mark.
    ///   - linkage: Where the record goes; libghostty's by default.
    init(gate: TerminalContentsGate, trace: TraceRuntime = .shared, probe: TypingLatencyProbe = .shared,
         linkage: Linkage = .libghostty) {
        let recorder = Recorder(gate: gate, trace: trace, probe: probe)
        // SAFETY: one retain for the process, never released (`context`'s note).
        let context = unsafe Unmanaged.passRetained(recorder).toOpaque()
        self.recorder = recorder
        // SAFETY: as above.
        self.context = unsafe context
        switch linkage {
        case .libghostty: setter = unsafe GhosttyTraceHook.libghosttySetter(context: context)
        case .custom(let custom): setter = custom
        case .unsupported: setter = nil
        }
    }

    /// Whether the linked libghostty has the hook.
    public var isSupported: Bool { setter != nil }

    /// Whether every surface reports its presented frames (`presented_cb`, `GHOSTTY_RENDERER_FRAMES`): then
    /// those are the frame marks, not the handoff.
    nonisolated static var presentsFrames: Bool {
        #if GHOSTTY_RENDERER_FRAMES
        true
        #else
        false
        #endif
    }

    /// Whether echo stages see frames without the DEBUG swizzle: the hook's handoffs or the presented frames.
    var seesFrames: Bool { isSupported || Self.presentsFrames }

    /// `ghostty_set_trace_hook` with a record for `context` that stays for the process (ghostty.h: a call in
    /// flight may read it after a later install returns); nil when the pinned GhosttyNextKit has no hook.
    private static func libghosttySetter(context: UnsafeMutableRawPointer) -> Setter? {
        #if GHOSTTY_TRACE_HOOK
        // SAFETY: one record for the process, never freed (ghostty.h keeps the pointer, and a call in flight
        // may read it after a later install); `context` is the recorder retained for the process.
        let record = unsafe UnsafeMutablePointer<ghostty_trace_hook_s>.allocate(capacity: 1)
        // SAFETY: as above; the callback has ghostty_trace_hook_cb's signature.
        unsafe record.initialize(to: ghostty_trace_hook_s(callback: ghosttyTraceHook, ctx: context))
        return { installed in
            // SAFETY: the record above, live for the process; nil removes the hook (ghostty.h).
            unsafe ghostty_set_trace_hook(installed ? UnsafePointer(record) : nil)
        }
        #else
        return nil
        #endif
    }

    // MARK: surfaces

    /// Reads the hook's calls for `surface`'s frames from now on, right after `ghostty_surface_new`.
    ///
    /// - Returns: The surface's trace id, for ``unregister(id:)``; 0 when the hook is unsupported or the
    ///   table is full (the surface's frames are then not traced).
    func register(_ frames: Surface, of surface: ghostty_surface_t) -> UInt64 {
        #if GHOSTTY_TRACE_HOOK
        // SAFETY: the caller's live surface, just made; the call only reads its id.
        let id = unsafe ghostty_surface_trace_id(surface)
        return register(frames, id: id) ? id : 0
        #else
        return 0
        #endif
    }

    /// Reads the hook's calls for the surface whose `ghostty_surface_trace_id` is `id`.
    ///
    /// - Returns: false when the table is full.
    func register(_ frames: Surface, id: UInt64) -> Bool {
        recorder.surfaces.insert(frames, id: id)
    }

    /// Stops reading calls for surface `id`, after `ghostty_surface_free` returned: every call from another
    /// thread for it has returned by then (free joins its renderer thread and waits for its frames in
    /// flight), and a present still queued to main for it finds no surface.
    func unregister(id: UInt64) {
        guard id != 0 else { return }
        recorder.surfaces.remove(id: id)
    }

    // MARK: demand

    /// Connects the hook to the app, once, at the composition root: the GPU completion of each key echo frame
    /// handed over before it goes to `presents` (until then echo commits do not wait for the GPU), and the
    /// record follows its demand (``followDemand(post:)``); both post visible work on `mainWork`.
    public func connect(on mainWork: MainWorkScheduler, presents: FramePresentEstimate) {
        let gpuOwner = mainWork.board.owner("GhosttyTraceHook.gpuDone")
        recorder.deliverGPU(GPUDelivery(post: { body in mainWork.postFromAnyThread(.visible, owner: gpuOwner, body) },
                                        finished: { flow, nanos in presents.gpuDidFinish(flow: flow, atNanos: nanos) }))
        let demandOwner = mainWork.board.owner("GhosttyTraceHook.demand")
        followDemand(post: { body in mainWork.postFromAnyThread(.visible, owner: demandOwner, body) })
    }

    /// Counts every frame a surface presented (``ghosttySurfacePresented(_:_:_:_:)``) in `frames`, the app's
    /// ``RenderStats``, from the Core Animation thread that reports it. The composition root calls it once; the
    /// first one given stays for the process.
    public func countPresentedFrames(in frames: RenderStats.PresentedFrames) {
        recorder.countPresentedFrames(in: frames)
    }

    /// Keeps the record installed exactly while something reads it, from now on: each change of the trace
    /// categories (`trace.start`, `trace.stop`, the keystroke-timing gate) and each start or stop of the
    /// typing probe's flows refreshes it through `post`, which runs its body on main (tests run it at once).
    func followDemand(post: @escaping @Sendable (_ body: @escaping @MainActor @Sendable () -> Void) -> Void) {
        let refresh: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            post { self.refreshDemand() }
        }
        recorder.trace.observeCategories { _ in refresh() }
        recorder.probe.observeRecording { _ in refresh() }
        refreshDemand()
    }

    /// The echo stages got their sink: their surfaces' handoffs are read from now on.
    func echoStagesInstalled() {
        echoStagesNeedFrames = true
        refreshDemand()
    }

    /// Installs the record while something reads it and removes it otherwise.
    func refreshDemand() {
        // This libghostty reports every handoff or presented frame, so a key.echo_frame sample can end: turn the
        // probe's sampling on.
        if seesFrames { recorder.probe.startEchoSampling() }
        guard let setter else { return }
        let wanted = echoStagesNeedFrames || recorder.probe.isRecording || recorder.probe.samplesEchoFrames
            || recorder.trace.isEnabled(categoryBit: SignpostCategory.ghostty.traceBit)
            || recorder.trace.isEnabled(categoryBit: SignpostCategory.frame.traceBit)
        guard wanted != isInstalled else { return }
        isInstalled = wanted
        setter(wanted)
    }
}

#if GHOSTTY_TRACE_HOOK
extension GhosttyTraceHook.Event {
    /// The event a `ghostty_trace_event_e` names; nil for one this build does not know.
    nonisolated init?(_ event: ghostty_trace_event_e) {
        switch event {
        case GHOSTTY_TRACE_FRAME_BEGIN: self = .frameBegin
        case GHOSTTY_TRACE_FRAME_END: self = .frameEnd
        case GHOSTTY_TRACE_CONTENTS_SET: self = .contentsSet
        case GHOSTTY_TRACE_GPU_DONE: self = .gpuDone
        case GHOSTTY_TRACE_IO_WRITE: self = .ioWrite
        case GHOSTTY_TRACE_SURFACE_DESTROY: self = .surfaceDestroy
        default: return nil
        }
    }
}

/// `ghostty_trace_hook_cb`: any Ghostty thread (renderer, main, Metal completion, input writers), maybe with
/// Ghostty's draw or terminal lock held, so it never blocks or calls into Ghostty. `ctx` is the hook's
/// ``GhosttyTraceHook/Recorder``, `surface` a `ghostty_surface_trace_id`.
// perf-hot: 0.05us terminal-key
nonisolated func ghosttyTraceHook(_ context: UnsafeMutableRawPointer?, _ event: ghostty_trace_event_e,
                                  _ surface: UInt64, _ seq: UInt64) {
    // SAFETY: `context` is the recorder the hook retained for the process (GhosttyTraceHook's `context`).
    guard let context = unsafe context, let event = GhosttyTraceHook.Event(event) else { return }
    // SAFETY: as above.
    unsafe GhosttyTraceHook.Recorder.receive(context: context, event, surface: surface, seq: seq)
}
#endif

/// `ghostty_surface_presented_cb` (ghostty-next p03-rendering-080), set in every surface's config under
/// `GHOSTTY_RENDERER_FRAMES`: on a Core Animation thread, once per frame the renderer presented. `userdata` is the
/// surface's ``SurfaceBridge`` (`presented_userdata`), which outlives the surface; `presentedTime` is 0 for a
/// frame that was not shown, which marks nothing (the next shown frame carries its echo). It never blocks, waits
/// for main or calls into Ghostty, as ghostty.h requires; it takes a lock only while the typing probe records or
/// a DEBUG new-terminal trace is armed, as the handoff does.
// perf-hot: 0.05us terminal-key
nonisolated func ghosttySurfacePresented(_ userdata: UnsafeMutableRawPointer?, _ frameID: UInt64, _ hostTime: UInt64,
                                         _ presentedTime: Double) {
    guard presentedTime > 0 else { return }
    // SAFETY: a surface's `presented_userdata`, its SurfaceBridge, which stays alive until after
    // ghostty_surface_free returns, and no call starts after that (ghostty.h); borrowed for this call only.
    guard let raw = unsafe userdata else { return }
    // SAFETY: as above.
    unsafe Unmanaged<SurfaceBridge>.fromOpaque(raw)._withUnsafeGuaranteedRef { bridge in
        bridge.frameMarks?.presented(on: bridge.frames, frameID: frameID)
    }
}
