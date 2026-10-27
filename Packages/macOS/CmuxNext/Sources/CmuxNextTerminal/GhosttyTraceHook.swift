import CmuxNextCompat
public import CmuxNextDesign
public import CmuxNextSignposts
import CmuxNextTrace
public import CmuxNextWakeups
import Darwin

/// cmux's end of ghostty-next's trace hook (p09-observability-048, -049): the renderer's own frames in the
/// app's trace ring and the frame marks of its key echoes, in Release builds too.
///
/// The hook is one process-wide C function pointer that Ghostty loads at each of its frame points, as
/// Chromium's embedders get a renderer's frame timing through a callback the embedder registers
/// (base/trace_event/trace_log.h, `TraceLog::SetAddTraceEventOverrides`), not by patching the renderer.
/// It records:
/// - `ghostty.render` (B/E on the renderer thread) around each `drawFrame`, arg0 the surface's
///   ``TypingLatencyProbe/SurfaceKey/traceID``, arg1 the flow of the press whose echo that frame shows
///   (0: none), so a STRESS trace shows it between `app.output.parsed` and `frame.commit`;
/// - `frame.gpu_done` (instant) from the frame's Metal completion handler, arg0 the surface, arg1 its seq;
/// - the IOSurface handoff: the surface's ``TerminalEchoStage/contentsSet()`` while the contents gate is
///   open, and the probe's ``TypingLatencyProbe/Mark/contents`` for the surface's parsed presses
///   (key.echo_frame's sample end, p09-observability-054). Once the app gave the hook its presents
///   (``deliverGPUCompletions(on:to:)``), a frame handed over before its GPU work ended marks its commit
///   `awaitsGPU`, and its completion posts those flows to ``FramePresentEstimate/gpuDidFinish(flow:atNanos:)``.
///
/// The pointer is set only while something reads it (``refreshDemand()``): an echo stage sink, the typing
/// probe's recording or its `key.echo_frame` sampling (``TypingLatencyProbe/samplesEchoFrames``, which the first
/// ``refreshDemand()`` turns on, so the hook stays set and a handoff between samples pays one load), or the
/// `ghostty` or `frame` trace category; otherwise it is null and a Ghostty frame pays one load.
/// The ABI it expects from ghostty-next's `ghostty.h`:
///
/// ```c
/// typedef void (*ghostty_trace_hook_cb)(void *ctx, uint32_t event, uint64_t surface, uint64_t seq);
/// void ghostty_set_trace_hook(ghostty_trace_hook_cb cb, void *ctx); // cb NULL: off
/// ```
///
/// `surface` is the surface's `userdata` (``SurfaceBridge``), `seq` the surface's frame number (from 1; a
/// frame's begin, end, handoff and GPU completion share it), and every event of a surface fires before
/// `ghostty_surface_free` returns, as `io_write_cb` does.
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
    /// `ghostty_trace_hook_cb`.
    typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UInt32, UInt64, UInt64) -> Void
    /// Sets (or, with a nil callback, clears) the process's hook: `ghostty_set_trace_hook`.
    typealias Setter = (Callback?, UnsafeMutableRawPointer?) -> Void

    /// `GHOSTTY_TRACE_*`: what a hook call marks.
    nonisolated enum Event: UInt32 {
        case frameBegin = 1
        case frameEnd = 2
        case contentsHandoff = 3
        case gpuDone = 4
        case ioWrite = 5
        case surfaceDestroy = 6
    }

    /// What every hook call reads, from any thread.
    let recorder: Recorder
    /// SAFETY: `ghostty_set_trace_hook` or a test's stand-in, set once in `init`; it is only called
    /// with ``ghosttyTraceHook`` and `context`, or with nil and nil.
    @safe private let setter: Setter?
    /// The recorder as the hook's `ctx`: retained once for the process, since a call already past Ghostty's
    /// load of the pointer may still run after the hook is cleared.
    /// SAFETY: the retain in `init` is never released, so the address stays a live Recorder for
    /// every hook call.
    @safe private let context: UnsafeMutableRawPointer
    /// Whether the pointer is set now.
    public private(set) var isInstalled = false
    /// An echo stage sink is installed (``TerminalEchoStages/install(_:)``): its stages need the handoffs.
    private var echoStagesNeedFrames = false

    /// - Parameters:
    ///   - gate: The process's contents gate (``TerminalEchoStages/contentsGate``).
    ///   - trace: The runtime the records go to.
    ///   - probe: The typing probe the handoffs mark.
    ///   - setter: `ghostty_set_trace_hook`; nil: the linked libghostty has no hook (``linkedSetter()``).
    init(gate: TerminalContentsGate, trace: TraceRuntime = .shared, probe: TypingLatencyProbe = .shared,
         setter: Setter? = GhosttyTraceHook.linkedSetter()) {
        recorder = Recorder(gate: gate, trace: trace, probe: probe)
        // SAFETY: the setter the caller passed (`setter`'s note), stored once.
        self.setter = unsafe setter
        // SAFETY: one retain for the process, never released (`context`'s note).
        context = unsafe Unmanaged.passRetained(recorder).toOpaque()
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

    /// `ghostty_set_trace_hook` from the linked libghostty, looked up by name so cmux builds against a
    /// GhosttyNextKit from before p09-observability-048; nil there.
    /// SAFETY: the lookup only reads the loaded images' symbol tables; calling the setter it returns
    /// is the unsafe part, and each call is marked.
    @safe nonisolated static func linkedSetter() -> Setter? {
        typealias SetHook = @convention(c) (Callback?, UnsafeMutableRawPointer?) -> Void
        // SAFETY: -2 is RTLD_DEFAULT (dlfcn.h), a handle value, not an address; the name is a
        // NUL-terminated copy Swift passes for the call.
        guard let symbol = unsafe dlsym(UnsafeMutableRawPointer(bitPattern: -2), "ghostty_set_trace_hook") else { return nil }
        // SAFETY: the symbol is ghostty.h's `void ghostty_set_trace_hook(ghostty_trace_hook_cb, void *)`,
        // which SetHook spells (this type's ABI note).
        let set = unsafe unsafeBitCast(symbol, to: SetHook.self)
        return { callback, context in
            // SAFETY: as above; the arguments are the caller's (`setter`'s note).
            unsafe set(callback, context)
        }
    }

    /// Posts the GPU completion of each key echo frame handed over before it to `presents`, as visible work
    /// on `mainWork`. The composition root calls it once; until then echo commits do not wait for the GPU.
    public func deliverGPUCompletions(on mainWork: MainWorkScheduler, to presents: FramePresentEstimate) {
        let owner = mainWork.board.owner("GhosttyTraceHook.gpuDone")
        recorder.deliverGPU(GPUDelivery(post: { body in mainWork.postFromAnyThread(.visible, owner: owner, body) },
                                        finished: { flow, nanos in presents.gpuDidFinish(flow: flow, atNanos: nanos) }))
    }

    /// Counts every frame a surface presented (``ghosttySurfacePresented(_:_:_:_:)``) in `frames`, the app's
    /// ``RenderStats``, from the Core Animation thread that reports it. The composition root calls it once; the
    /// first one given stays for the process.
    public func countPresentedFrames(in frames: RenderStats.PresentedFrames) {
        recorder.countPresentedFrames(in: frames)
    }

    /// The echo stages got their sink: their surfaces' handoffs are read from now on.
    func echoStagesInstalled() {
        echoStagesNeedFrames = true
        refreshDemand()
    }

    /// Sets the hook while something reads it and clears it otherwise. Call it at start and after the typing
    /// probe's flows or the trace categories change (`trace.start`, `trace.stop`).
    public func refreshDemand() {
        // This libghostty reports every handoff or presented frame, so a key.echo_frame sample can end: turn the
        // probe's sampling on.
        if seesFrames { recorder.probe.startEchoSampling() }
        guard let setter else { return }
        let wanted = echoStagesNeedFrames || recorder.probe.isRecording || recorder.probe.samplesEchoFrames
            || recorder.trace.isEnabled(categoryBit: SignpostCategory.ghostty.traceBit)
            || recorder.trace.isEnabled(categoryBit: SignpostCategory.frame.traceBit)
        guard wanted != isInstalled else { return }
        isInstalled = wanted
        if wanted {
            // SAFETY: the hook has ghostty_trace_hook_cb's signature and `context` is the recorder
            // retained for the process (its note), so every call Ghostty makes gets a live one.
            unsafe setter(ghosttyTraceHook, context)
        } else {
            // SAFETY: nil clears the hook (this type's ABI note).
            unsafe setter(nil, nil)
        }
    }
}

extension GhosttyTraceHook {
    /// Where GPU completions go: `post` runs its body on main, which gives each flow to `finished`.
    nonisolated final class GPUDelivery: Sendable {
        let post: @Sendable (_ body: @escaping @MainActor @Sendable () -> Void) -> Void
        let finished: @MainActor @Sendable (_ flow: UInt64, _ nanos: UInt64) -> Void

        init(post: @escaping @Sendable (_ body: @escaping @MainActor @Sendable () -> Void) -> Void,
             finished: @escaping @MainActor @Sendable (_ flow: UInt64, _ nanos: UInt64) -> Void) {
            self.post = post
            self.finished = finished
        }
    }

    /// One surface's hook state, held by its ``SurfaceBridge`` (the surface's `userdata`). Its handoffs come
    /// from one thread at a time; its GPU completions from Metal's.
    nonisolated final class Surface: Sendable {
        /// Flows whose frame went to its layer before its GPU work ended, held at once per surface.
        static let gpuWaitCapacity = 8

        /// One flow waiting for its frame's GPU completion: `flow` 0 when free. Only the handoff stores into
        /// a free slot (seq first); whoever exchanges `flow` back to 0 delivers it.
        nonisolated final class GPUWait: Sendable {
            let flow = Atomic<UInt64>(0)
            let seq = Atomic<UInt64>(0)
        }

        let key: TypingLatencyProbe.SurfaceKey
        let echoStage: TerminalEchoStage?
        /// A `ghostty.render` begin was written and its end is due.
        let renderOpen = Atomic<Bool>(false)
        /// Every frame below this seq finished its GPU work.
        let gpuDoneBelow = Atomic<UInt64>(0)
        let gpuWaits: [GPUWait]

        init(key: TypingLatencyProbe.SurfaceKey, echoStage: TerminalEchoStage?) {
            self.key = key
            self.echoStage = echoStage
            gpuWaits = (0..<Self.gpuWaitCapacity).map { _ in GPUWait() }
        }

        /// Holds `flows` of frame `seq` for its GPU completion; returns the ones it already had.
        func awaitGPU(_ flows: [UInt64], seq: UInt64) -> [UInt64] {
            for flow in flows {
                guard let free = gpuWaits.first(where: { $0.flow.load(ordering: .acquiring) == 0 }) else { break }
                free.seq.store(seq, ordering: .relaxed)
                free.flow.store(flow, ordering: .releasing)
            }
            // A completion that ran between the caller's check and the stores above found nothing to take.
            return takeFinished()
        }

        /// Records that frame `seq`'s GPU work finished; returns the flows that waited for it or an earlier frame.
        func gpuDidFinish(seq: UInt64) -> [UInt64] {
            var below = gpuDoneBelow.load(ordering: .relaxed)
            // wakeup-allow: bounded: a compare-exchange retry; it loops only when another completion moved it first.
            while below <= seq {
                let (exchanged, original) = gpuDoneBelow.compareExchange(expected: below, desired: seq &+ 1,
                                                                         ordering: .acquiringAndReleasing)
                if exchanged { break }
                below = original
            }
            return takeFinished()
        }

        /// Takes the waiting flows whose frame's GPU work finished.
        private func takeFinished() -> [UInt64] {
            let below = gpuDoneBelow.load(ordering: .acquiring)
            var finished: [UInt64] = []
            for wait in gpuWaits where wait.flow.load(ordering: .acquiring) != 0 && wait.seq.load(ordering: .relaxed) < below {
                let flow = wait.flow.exchange(0, ordering: .acquiringAndReleasing)
                if flow != 0 { finished.append(flow) }
            }
            return finished
        }
    }

    /// The hook's work for one call, on the thread Ghostty calls from. Never locks or allocates while the
    /// typing probe is off.
    nonisolated final class Recorder: Sendable {
        let gate: TerminalContentsGate
        let trace: TraceRuntime
        let probe: TypingLatencyProbe
        /// The ``GPUDelivery`` (``deliverGPU(_:)``), empty until the app gives one.
        private let gpuDelivery = ProcessOnceSlot<GPUDelivery>()
        /// The app's ``RenderStats`` counts of presented frames (``countPresentedFrames(in:)``), empty until given.
        private let presentedFrameCounts = ProcessOnceSlot<RenderStats.PresentedFrames>()

        init(gate: TerminalContentsGate, trace: TraceRuntime, probe: TypingLatencyProbe) {
            self.gate = gate
            self.trace = trace
            self.probe = probe
        }

        /// Sends GPU completions to `delivery` from now on; the first one given stays for the process.
        func deliverGPU(_ delivery: GPUDelivery) {
            gpuDelivery.install(delivery)
        }

        /// Counts presented frames in `frames` from now on; the first one given stays for the process.
        func countPresentedFrames(in frames: RenderStats.PresentedFrames) {
            presentedFrameCounts.install(frames)
        }

        /// Whether the app gave its ``GPUDelivery``.
        private var deliversGPU: Bool { gpuDelivery.isInstalled }

        /// Runs `body` with the ``GPUDelivery`` given; nothing until the app gives one.
        private func withGPUDelivery(_ body: (GPUDelivery) -> Void) {
            gpuDelivery.withObject(body)
        }

        func record(_ event: Event, on surface: Surface, seq: UInt64) {
            switch event {
            case .frameBegin:
                guard trace.isEnabled(categoryBit: SignpostName.ghosttyRender.traceCategory.traceBit) else { return }
                let flow = probe.echoFlow(on: surface.key) ?? 0
                if trace.begin(.ghosttyRender, arg0: surface.key.traceID, arg1: flow) {
                    surface.renderOpen.store(true, ordering: .relaxed)
                }
            case .frameEnd, .surfaceDestroy:
                guard surface.renderOpen.exchange(false, ordering: .relaxed) else { return }
                trace.writeEnd(name: SignpostName.ghosttyRender.rawValue, categoryBit: SignpostName.ghosttyRender.traceCategory.traceBit,
                               phase: .end, arg0: surface.key.traceID)
            case .contentsHandoff:
                // Presented frames are the marks when the surfaces report them (``presented(on:frameID:)``).
                guard !GhosttyTraceHook.presentsFrames else { return }
                frameShown(on: surface, seq: seq, gpuMayRun: true)
            case .gpuDone:
                trace.event(.frameGPUDone, arg0: surface.key.traceID, arg1: seq)
                deliver(surface.gpuDidFinish(seq: seq))
            case .ioWrite:
                return // Ghostty's io_write_cb marks the write (``TypingLatencyProbe/inputWritten(on:)``).
            }
        }

        /// The renderer presented frame `frameID` of `surface` (``ghosttySurfacePresented(_:_:_:_:)``) from a Core
        /// Animation thread: the frame mark of the echo stage, the probe and the new-terminal trace. Its GPU work
        /// is done, so no commit waits for it.
        func presented(on surface: Surface, frameID: UInt64) {
            presentedFrameCounts.withObject { $0.framePresented(by: TerminalSurfaceView.self) }
            frameShown(on: surface, seq: frameID, gpuMayRun: false)
        }

        /// Frame `seq` of `surface` reached the screen's path: the echo stage's frame, the probe's contents mark
        /// for the surface's parsed presses and, while armed, the new-terminal trace's contents. `gpuMayRun`: the
        /// frame was handed over before its GPU completion may have run (the handoff), so its commits wait for it.
        private func frameShown(on surface: Surface, seq: UInt64, gpuMayRun: Bool) {
            if gate.isOpen { surface.echoStage?.contentsSet() }
            #if (DEBUG || CMUX_BENCH_HOOKS) && GHOSTTY_RENDERER_FRAMES
            // No layer gets the frame (TypingFrameProbe): the trace watches this surface's frames.
            if NewTerminalTrace.shared.isArmed { NewTerminalTrace.shared.contents(layer: ObjectIdentifier(surface)) }
            #endif
            guard probe.isRecording else { return }
            let awaitsGPU = gpuMayRun && deliversGPU && surface.gpuDoneBelow.load(ordering: .acquiring) <= seq
            let flows = probe.mark(.contents, surface: surface.key, awaitsGPU: awaitsGPU)
            guard awaitsGPU, !flows.isEmpty else { return }
            deliver(surface.awaitGPU(flows, seq: seq))
        }

        /// Posts each flow's GPU completion, now, to the presents (the ``GPUDelivery`` given).
        private func deliver(_ flows: [UInt64]) {
            guard !flows.isEmpty else { return }
            let nanos = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            withGPUDelivery { delivery in
                let finished = delivery.finished
                delivery.post { for flow in flows { finished(flow, nanos) } }
            }
        }
    }
}

/// `ghostty_trace_hook_cb`: any Ghostty thread (renderer, IO, Metal completion). `ctx` is the hook's
/// ``GhosttyTraceHook/Recorder``, `surface` the surface's ``SurfaceBridge``.
// perf-hot: 0.05us terminal-key
nonisolated func ghosttyTraceHook(_ context: UnsafeMutableRawPointer?, _ event: UInt32, _ surface: UInt64, _ seq: UInt64) {
    // SAFETY: `context` is the recorder the hook retained for the process (GhosttyTraceHook's
    // `context`); `surface` is a live surface's userdata, its SurfaceBridge, which outlives the
    // surface, and each event of a surface fires before ghostty_surface_free returns (the ABI note).
    // Both are borrowed for this call only.
    guard let context = unsafe context, let event = GhosttyTraceHook.Event(rawValue: event),
          let bridge = unsafe UnsafeMutableRawPointer(bitPattern: UInt(truncatingIfNeeded: surface)) else { return }
    // SAFETY: as above.
    unsafe Unmanaged<GhosttyTraceHook.Recorder>.fromOpaque(context)._withUnsafeGuaranteedRef { recorder in
        // SAFETY: as above.
        unsafe Unmanaged<SurfaceBridge>.fromOpaque(bridge)._withUnsafeGuaranteedRef { bridge in
            recorder.record(event, on: bridge.frames, seq: seq)
        }
    }
}

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
