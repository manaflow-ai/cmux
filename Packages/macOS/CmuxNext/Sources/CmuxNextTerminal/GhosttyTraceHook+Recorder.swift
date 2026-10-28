import CmuxNextCompat
import CmuxNextDesign
import CmuxNextSignposts
import CmuxNextTrace
import CmuxNextWakeups
import Darwin

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

    /// The hook's work for one call, on the thread Ghostty calls from. Never locks or allocates while the
    /// typing probe is off.
    nonisolated final class Recorder: Sendable {
        /// Surfaces tracked at once; past it a new surface's frames are not traced.
        static let surfaceCapacity = 4_096

        let gate: TerminalContentsGate
        let trace: TraceRuntime
        let probe: TypingLatencyProbe
        /// The registered surfaces by trace id (``GhosttyTraceHook/register(_:id:)``).
        let surfaces = SurfaceTable(capacity: Recorder.surfaceCapacity)
        /// The ``GPUDelivery`` (``deliverGPU(_:)``), empty until the app gives one.
        private let gpuDelivery = ProcessOnceSlot<GPUDelivery>()
        /// The app's ``RenderStats`` counts of presented frames (``countPresentedFrames(in:)``), empty until given.
        private let presentedFrameCounts = ProcessOnceSlot<RenderStats.PresentedFrames>()

        init(gate: TerminalContentsGate, trace: TraceRuntime, probe: TypingLatencyProbe) {
            self.gate = gate
            self.trace = trace
            self.probe = probe
        }

        /// One hook call for the recorder at `context` (the record's `ctx`), as `ghostty_trace_hook_cb` gets it.
        // perf-hot: 0.05us terminal-key
        static func receive(context: UnsafeMutableRawPointer, _ event: Event, surface id: UInt64, seq: UInt64) {
            // SAFETY: `context` is the recorder GhosttyTraceHook retained for the process (its `context`), borrowed
            // for this call only.
            unsafe Unmanaged<Recorder>.fromOpaque(context)._withUnsafeGuaranteedRef { $0.record(event, surface: id, seq: seq) }
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

        /// Records `event` of the surface whose trace id is `id`; nothing for an id the table does not have.
        func record(_ event: Event, surface id: UInt64, seq: UInt64) {
            guard event != .ioWrite, let surface = surfaces.surface(id) else { return }
            // SAFETY: the table holds a surface only between its registration and its unregistration after
            // `ghostty_surface_free` returned, while its SurfaceBridge keeps it alive (SurfaceTable's note).
            unsafe surface._withUnsafeGuaranteedRef { record(event, on: $0, seq: seq) }
        }

        private func record(_ event: Event, on surface: Surface, seq: UInt64) {
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
            case .contentsSet:
                // Presented frames are the marks when the surfaces report them (``presented(on:frameID:)``).
                guard !GhosttyTraceHook.presentsFrames, surface.takeFirstContents(seq) else { return }
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
            let awaitsGPU = gpuMayRun && deliversGPU && !surface.gpuFinished(seq)
            let flows = probe.mark(.contents, surface: surface.key, awaitsGPU: awaitsGPU)
            guard awaitsGPU, !flows.isEmpty else { return }
            deliver(surface.awaitGPU(flows, seq: seq))
        }

        /// Posts each flow's GPU completion, now, to the presents (the ``GPUDelivery`` given).
        private func deliver(_ flows: [UInt64]) {
            guard !flows.isEmpty else { return }
            let nanos = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            gpuDelivery.withObject { delivery in
                let finished = delivery.finished
                delivery.post { for flow in flows { finished(flow, nanos) } }
            }
        }
    }
}
