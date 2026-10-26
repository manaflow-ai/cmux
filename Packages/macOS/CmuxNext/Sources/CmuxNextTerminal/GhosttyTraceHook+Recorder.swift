import CmuxNextCompat
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
        /// The address of the retained ``GPUDelivery`` (``deliverGPU(_:)``), 0 until the app gives one.
        private let gpuDelivery = Atomic<UInt64>(0)

        init(gate: TerminalContentsGate, trace: TraceRuntime, probe: TypingLatencyProbe) {
            self.gate = gate
            self.trace = trace
            self.probe = probe
        }

        /// One hook call for the recorder at `context` (the record's `ctx`), as `ghostty_trace_hook_cb` gets it.
        // perf-hot: 0.05us terminal-key
        static func receive(context: UnsafeMutableRawPointer, _ event: Event, surface id: UInt64, seq: UInt64) {
            Unmanaged<Recorder>.fromOpaque(context)._withUnsafeGuaranteedRef { $0.record(event, surface: id, seq: seq) }
        }

        /// Sends GPU completions to `delivery` from now on; the first one given stays for the process.
        func deliverGPU(_ delivery: GPUDelivery) {
            let retained = Unmanaged.passRetained(delivery)
            let address = UInt64(UInt(bitPattern: retained.toOpaque()))
            if !gpuDelivery.compareExchange(expected: 0, desired: address, ordering: .acquiringAndReleasing).exchanged {
                retained.release()
            }
        }

        /// The ``GPUDelivery`` given, read with no reference-count traffic.
        private var gpuSink: Unmanaged<GPUDelivery>? {
            UnsafeRawPointer(bitPattern: UInt(gpuDelivery.load(ordering: .acquiring))).map { Unmanaged.fromOpaque($0) }
        }

        /// Records `event` of the surface whose trace id is `id`; nothing for an id the table does not have.
        func record(_ event: Event, surface id: UInt64, seq: UInt64) {
            guard event != .ioWrite, let surface = surfaces.surface(id) else { return }
            surface._withUnsafeGuaranteedRef { record(event, on: $0, seq: seq) }
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
                guard surface.takeFirstContents(seq) else { return }
                if gate.isOpen { surface.echoStage?.contentsSet() }
                guard probe.isRecording else { return }
                let delivery = gpuSink
                let awaitsGPU = delivery != nil && !surface.gpuFinished(seq)
                let flows = probe.mark(.contents, surface: surface.key, awaitsGPU: awaitsGPU)
                guard let delivery, awaitsGPU, !flows.isEmpty else { return }
                deliver(surface.awaitGPU(flows, seq: seq), to: delivery)
            case .gpuDone:
                trace.event(.frameGPUDone, arg0: surface.key.traceID, arg1: seq)
                let finished = surface.gpuDidFinish(seq: seq)
                guard let delivery = gpuSink, !finished.isEmpty else { return }
                deliver(finished, to: delivery)
            case .ioWrite:
                return // Ghostty's io_write_cb marks the write (``TypingLatencyProbe/inputWritten(on:)``).
            }
        }

        /// Posts each flow's GPU completion, now, to the presents.
        private func deliver(_ flows: [UInt64], to delivery: Unmanaged<GPUDelivery>) {
            guard !flows.isEmpty else { return }
            let nanos = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            delivery._withUnsafeGuaranteedRef { delivery in
                let finished = delivery.finished
                delivery.post { for flow in flows { finished(flow, nanos) } }
            }
        }
    }
}
