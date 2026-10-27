import CmuxNextCompat
@testable import CmuxNextDesign
import CmuxNextMetrics
@testable import CmuxNextSignposts
@testable import CmuxNextTerminal
@testable import CmuxNextTrace
@testable import CmuxNextWakeups
import Darwin
import Dispatch
import Testing

/// The Ghostty trace hook (p09-observability-049): `ghostty.render` around a frame, `frame.gpu_done` at its GPU
/// completion, the IOSurface handoff as the echo stages' frame and the typing probe's contents mark, the GPU
/// completion of a frame handed over before it, and the pointer set only while something reads it. The hook is
/// called the way ghostty-next calls it, through the callback the hook gives `ghostty_set_trace_hook`.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct GhosttyTraceHookTests {
    /// The records a test runtime writes, in order.
    nonisolated final class RecordLog: Sendable {
        private let state = Mutex<[TraceRuntime.StubRecord]>([])

        var records: [TraceRuntime.StubRecord] { state.withLock { $0 } }

        /// A runtime with every category on, recording into this log.
        func runtime() -> TraceRuntime {
            let runtime = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { [self] record in
                state.withLock { $0.append(record) }
            })
            runtime.setCategoryMask(GhosttyTraceHookTests.allCategories)
            return runtime
        }
    }

    /// Every hop the probe emits, and every flow handed to the presents.
    nonisolated final class Heard: Sendable {
        private let hops = Mutex<[(String, UInt64)]>([])
        private let gpu = Mutex<[UInt64]>([])

        func hop(_ name: String, _ flow: UInt64) { hops.withLock { $0.append((name, flow)) } }
        func has(_ name: String, _ flow: UInt64) -> Bool { hops.withLock { $0.contains { $0 == (name, flow) } } }
        func gpuFinished(_ flow: UInt64) { gpu.withLock { $0.append(flow) } }
        var gpuFlows: [UInt64] { gpu.withLock { $0 } }
    }

    /// What the fake `ghostty_set_trace_hook` was last given.
    final class Installed {
        var callback: GhosttyTraceHook.Callback?
        var context: UnsafeMutableRawPointer?
        var calls = 0
    }

    nonisolated static let allCategories = SignpostCategory.allCases.reduce(UInt64(0)) { $0 | 1 << UInt64($1.traceBit) }

    /// A hook on `trace` and `probe`, one surface, and the installed callback. With `heard`, GPU completions are
    /// delivered to it at once (the test calls the hook on the main thread).
    struct Rig {
        let hook: GhosttyTraceHook
        let installed: Installed
        let bridge: SurfaceBridge
        let key: TypingLatencyProbe.SurfaceKey

        init(trace: TraceRuntime, probe: TypingLatencyProbe, heard: Heard? = nil, gate: TerminalContentsGate = TerminalContentsGate(),
             echoStage: TerminalEchoStage? = nil) {
            let installed = Installed()
            hook = GhosttyTraceHook(gate: gate, trace: trace, probe: probe, setter: { callback, context in
                installed.callback = callback
                installed.context = context
                installed.calls += 1
            })
            if let heard {
                hook.recorder.deliverGPU(GhosttyTraceHook.GPUDelivery(post: { body in MainActor.assumeIsolated { body() } },
                                                                      finished: { flow, _ in heard.gpuFinished(flow) }))
            }
            self.installed = installed
            key = probe.makeSurfaceKey()
            // The surface's input goes nowhere: these tests read only the trace hook.
            let lane = TerminalInputLane(drain: TerminalInputDrain(queue: DispatchQueue(label: "GhosttyTraceHookTests.input", qos: .utility)) { _, _ in .next })
            bridge = SurfaceBridge(input: TerminalInputSink(lane: lane, typingSurface: key), echoStage: echoStage,
                                   frameMarks: hook.recorder)
        }

        /// Calls the surface's `presented_cb` as the renderer does for frame `frameID`; `presentedTime` 0: not shown.
        func present(frameID: UInt64, presentedTime: Double = 1) {
            ghosttySurfacePresented(Unmanaged.passUnretained(bridge).toOpaque(), frameID, mach_absolute_time(), presentedTime)
        }

        /// Calls the installed hook as Ghostty does for this surface.
        func call(_ event: GhosttyTraceHook.Event, seq: UInt64) {
            let surface = UInt64(UInt(bitPattern: Unmanaged.passUnretained(bridge).toOpaque()))
            installed.callback?(installed.context, event.rawValue, surface, seq)
        }
    }

    /// One key press on `key` whose echo was parsed; returns its flow.
    private func parsedPress(_ probe: TypingLatencyProbe, on key: TypingLatencyProbe.SurfaceKey) throws -> UInt64 {
        probe.keyDown(eventTimestamp: 0)
        probe.keyReachedTerminal(key, display: 7)
        probe.terminalTookKey()
        probe.mark(.dispatchEnd)
        probe.inputWritten(on: key)
        let flow = try #require(probe.openFlow)
        probe.mark(.socketSubmit, flow: flow)
        probe.outputDecoded(flow: flow)
        probe.mark(.outputReceived, flow: flow)
        probe.mark(.outputParsed, flow: flow)
        return flow
    }

    @Test func aFrameIsOneRenderSliceAndItsGPUCompletionAnInstant() {
        let log = RecordLog()
        let trace = log.runtime()
        let rig = Rig(trace: trace, probe: TypingLatencyProbe(path: nil, trace: trace))
        rig.hook.refreshDemand()
        #expect(rig.hook.isInstalled)

        rig.call(.frameBegin, seq: 1)
        rig.call(.frameEnd, seq: 1)
        rig.call(.gpuDone, seq: 1)
        rig.call(.frameEnd, seq: 2) // an end with no begin written writes nothing

        let records = log.records
        #expect(records.map(\.name) == [SignpostName.ghosttyRender.rawValue, SignpostName.ghosttyRender.rawValue,
                                        SignpostName.frameGPUDone.rawValue])
        #expect(records.map(\.phase) == [.begin, .end, .instant])
        #expect(records.allSatisfy { $0.arg0 == rig.key.traceID })
        #expect(records.first?.arg1 == 0, "no press waits for this frame")
        #expect(records.last?.arg1 == 1, "frame.gpu_done names its frame's seq")
    }

    @Test func theHandoffMarksTheParsedPressAndItsPresentWaitsForTheGPU() throws {
        let log = RecordLog(), heard = Heard()
        let trace = log.runtime()
        let probe = TypingLatencyProbe(path: nil, trace: trace, hopRecorder: { heard.hop($0, $1) })
        probe.startFlows()
        defer { probe.stopFlows() }
        let rig = Rig(trace: trace, probe: probe, heard: heard)
        rig.hook.refreshDemand()
        let flow = try parsedPress(probe, on: rig.key)

        rig.call(.frameBegin, seq: 1)
        #expect(log.records.last?.arg1 == flow, "ghostty.render names the press whose echo it draws")
        rig.call(.frameEnd, seq: 1)
        rig.call(.contentsHandoff, seq: 1)
        #expect(heard.has("app.frame.contents", flow))
        probe.turnDidEnd()
        #expect(probe.takePresentCommits() == [FramePresentEstimate.Commit(flow: flow, display: 7, awaitsGPU: true)])
        #expect(heard.gpuFlows.isEmpty)

        rig.call(.gpuDone, seq: 1)
        #expect(heard.gpuFlows == [flow], "the GPU completion goes to the presents once")
        rig.call(.gpuDone, seq: 2)
        #expect(heard.gpuFlows == [flow])
    }

    /// Until the app gives the hook its presents, an echo commit never waits for a GPU completion nobody delivers.
    @Test func withNoDeliveryTheCommitDoesNotWaitForTheGPU() throws {
        let trace = RecordLog().runtime()
        let probe = TypingLatencyProbe(path: nil, trace: trace)
        probe.startFlows()
        defer { probe.stopFlows() }
        let rig = Rig(trace: trace, probe: probe)
        rig.hook.refreshDemand()
        let flow = try parsedPress(probe, on: rig.key)

        rig.call(.contentsHandoff, seq: 1)
        probe.turnDidEnd()
        #expect(probe.takePresentCommits() == [FramePresentEstimate.Commit(flow: flow, display: 7, awaitsGPU: false)])
    }

    @Test func aFrameWhoseGPUWorkEndedFirstDoesNotWait() throws {
        let heard = Heard()
        let trace = RecordLog().runtime()
        let probe = TypingLatencyProbe(path: nil, trace: trace)
        probe.startFlows()
        defer { probe.stopFlows() }
        let rig = Rig(trace: trace, probe: probe, heard: heard)
        rig.hook.refreshDemand()
        let flow = try parsedPress(probe, on: rig.key)

        rig.call(.gpuDone, seq: 1)
        rig.call(.contentsHandoff, seq: 1)
        probe.turnDidEnd()
        #expect(probe.takePresentCommits() == [FramePresentEstimate.Commit(flow: flow, display: 7, awaitsGPU: false)])
        #expect(heard.gpuFlows.isEmpty)
    }

    @Test func theHandoffIsTheEchoStagesFrame() throws {
        let stages = TerminalEchoStageTests.Rig()
        let trace = TraceRuntime(role: .app)
        let rig = Rig(trace: trace, probe: TypingLatencyProbe(path: nil, trace: trace), gate: stages.gate, echoStage: stages.stage)
        rig.hook.echoStagesInstalled()
        #expect(rig.hook.isInstalled, "an installed echo sink needs the handoffs")
        try stages.key(at: 1_000)
        stages.echo()
        #expect(stages.gate.isOpen)

        rig.call(.contentsHandoff, seq: 1)
        #expect(stages.sink.events == [.echoParsed, .contentSubmitted])
        #expect(!stages.gate.isOpen)
    }

    /// p03-rendering-081: with renderer-owned frames the renderer presents off main and reports each frame through
    /// the surface's `presented_cb`: that is the probe's contents mark, with no trace hook set, and a presented frame
    /// never waits for its GPU work. A frame that was not shown marks nothing.
    @Test func thePresentedFrameMarksTheParsedPressWithoutWaitingForTheGPU() throws {
        let heard = Heard()
        let trace = RecordLog().runtime()
        let probe = TypingLatencyProbe(path: nil, trace: trace, hopRecorder: { heard.hop($0, $1) })
        probe.startFlows()
        defer { probe.stopFlows() }
        let rig = Rig(trace: trace, probe: probe, heard: heard)
        let flow = try parsedPress(probe, on: rig.key)

        rig.present(frameID: 1, presentedTime: 0)
        #expect(!heard.has("app.frame.contents", flow), "a frame that was not shown shows no echo")
        rig.present(frameID: 2)
        #expect(heard.has("app.frame.contents", flow))
        #expect(!rig.hook.isInstalled, "the presented frames need no trace hook")
        probe.turnDidEnd()
        #expect(probe.takePresentCommits() == [FramePresentEstimate.Commit(flow: flow, display: 7, awaitsGPU: false)])
        #expect(heard.gpuFlows.isEmpty)
    }

    @Test func thePresentedFrameIsTheEchoStagesFrame() throws {
        let stages = TerminalEchoStageTests.Rig()
        let trace = TraceRuntime(role: .app)
        let rig = Rig(trace: trace, probe: TypingLatencyProbe(path: nil, trace: trace), gate: stages.gate, echoStage: stages.stage)
        try stages.key(at: 1_000)
        stages.echo()
        #expect(stages.gate.isOpen)

        rig.present(frameID: 1)
        #expect(stages.sink.events == [.echoParsed, .contentSubmitted])
        #expect(!stages.gate.isOpen)
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// p03-rendering-093: a renderer-presented frame passes through no `setContents:` hook, so each shown one is a
    /// contents set of TerminalSurfaceView in the app's RenderStats, once the app gave them; a frame not shown is not.
    @Test func eachShownPresentedFrameIsATerminalContentsSet() {
        let trace = TraceRuntime(role: .app)
        let rig = Rig(trace: trace, probe: TypingLatencyProbe(path: nil, trace: trace))
        let stats = RenderStats()
        stats.ledger.arm(generation: 1)
        defer { stats.ledger.disarm() }

        rig.present(frameID: 1)
        rig.hook.countPresentedFrames(in: stats.presentedFrames)
        rig.present(frameID: 2)
        rig.present(frameID: 3, presentedTime: 0)
        rig.present(frameID: 4)
        #expect(Self.terminalContentsSets(stats) == 2)
        #expect(stats.totals[.contentsSets] == 2)
    }

    /// p03-rendering-093: the Core Animation threads that report presented frames count them without a data race
    /// (run under TSan: `swift test --sanitize=thread`).
    @Test func presentedFramesFromManyThreadsCountWithoutARace() async {
        let trace = TraceRuntime(role: .app)
        let rig = Rig(trace: trace, probe: TypingLatencyProbe(path: nil, trace: trace))
        let stats = RenderStats()
        rig.hook.countPresentedFrames(in: stats.presentedFrames)
        stats.ledger.arm(generation: 1)
        defer { stats.ledger.disarm() }

        let bridge = UInt(bitPattern: Unmanaged.passUnretained(rig.bridge).toOpaque())
        await Self.presentOffMain(bridge: bridge, threads: 8, framesPerThread: 100)
        withExtendedLifetime(rig.bridge) {}
        #expect(Self.terminalContentsSets(stats) == 8 * 100)
    }

    private static func terminalContentsSets(_ stats: RenderStats) -> Int? {
        stats.owners().first { $0.key == RenderStats.classKey(TerminalSurfaceView.self) }?.totals[.contentsSets]
    }

    /// `threads` threads off the main thread each report `framesPerThread` shown frames of the surface whose
    /// bridge is at `bridge`, as the renderer's `presented_cb` does.
    nonisolated static func presentOffMain(bridge: UInt, threads: Int, framesPerThread: Int) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                DispatchQueue.concurrentPerform(iterations: threads) { thread in
                    for frame in 0..<framesPerThread {
                        let frameID = UInt64(thread * framesPerThread + frame + 1)
                        ghosttySurfacePresented(UnsafeMutableRawPointer(bitPattern: bridge), frameID, mach_absolute_time(), 1)
                    }
                }
                continuation.resume()
            }
        }
    }
    #endif

    @Test func theHookIsSetOnlyWhileSomethingReadsIt() {
        let trace = TraceRuntime(role: .app)
        let rig = Rig(trace: trace, probe: TypingLatencyProbe(path: nil, trace: trace))
        rig.hook.refreshDemand()
        #expect(!rig.hook.isInstalled && rig.installed.calls == 0, "nothing reads it: the pointer stays null")

        trace.setCategoryMask(1 << UInt64(SignpostCategory.frame.traceBit))
        rig.hook.refreshDemand()
        #expect(rig.hook.isInstalled && rig.installed.callback != nil && rig.installed.context != nil)
        rig.hook.refreshDemand()
        #expect(rig.installed.calls == 1, "a refresh that changes nothing does not set it again")

        trace.setCategoryMask(0)
        rig.hook.refreshDemand()
        #expect(!rig.hook.isInstalled && rig.installed.callback == nil && rig.installed.context == nil)

        let unsupported = GhosttyTraceHook(gate: TerminalContentsGate(), trace: trace, setter: nil)
        trace.setCategoryMask(Self.allCategories)
        unsupported.refreshDemand()
        #expect(!unsupported.isSupported && !unsupported.isInstalled)
    }

    /// p09-observability-054: the hook turns echo sampling on, sampling keeps the hook set with nothing recording,
    /// and the handoff of the frame that shows the sampled press's echo is its `key.echo_frame` sample end.
    @Test func echoSamplingKeepsTheHookSetAndItsHandoffEndsTheSample() throws {
        let trace = TraceRuntime(role: .app)
        let store = MetricsStore(role: .app, profile: MetricsProfile(appVersion: "1.0", buildNumber: "1", channel: "dev",
                                                                     osVersion: "26.1.0", hardwareClass: "Mac16,10",
                                                                     buildDay: MetricsProfile.Day(year: 2026, month: 10, day: 26)))
        store.attach(to: trace)
        let probe = TypingLatencyProbe(path: nil, trace: trace, echoFrames: Metrics(runtime: trace))
        let rig = Rig(trace: trace, probe: probe)
        #expect(!probe.samplesEchoFrames)
        rig.hook.refreshDemand()
        #expect(probe.samplesEchoFrames, "a libghostty with the hook ends samples, so the hook turns sampling on")
        #expect(rig.hook.isInstalled && !probe.isRecording, "echo sampling reads the handoffs while no press is open")

        for _ in 1..<TypingLatencyProbe.echoSampleInterval { probe.keyDown(eventTimestamp: 0) }
        _ = try parsedPress(probe, on: rig.key) // the 16th key
        rig.call(.contentsHandoff, seq: 1)
        #expect(!probe.isRecording, "the handoff closed the sample")
        let echo = store.delta().histograms.first { $0.name == HistogramID.keyEchoFrame(.local).name }
        #expect(echo?.count == 1)
    }

    /// A frame's four hook calls add no allocation to the loop that makes them, with every category on and the
    /// typing probe off: each count is compared with the same loop around nothing, because the Debug build's
    /// loop allocates by itself.
    @Test func aSyntheticFrameAllocatesNothing() throws {
        let trace = TraceRuntime(role: .app)
        trace.setCategoryMask(Self.allCategories)
        let rig = Rig(trace: trace, probe: TypingLatencyProbe(path: nil, trace: trace))
        rig.hook.refreshDemand()
        var seq: UInt64 = 0
        func allocations(_ frame: (UInt64) -> Void) -> Int? {
            MallocProbe.allocations {
                for _ in 0..<1_000 {
                    seq += 1
                    frame(seq)
                }
            }
        }

        var sink = 0
        let control = MallocProbe.allocations { sink += ContiguousArray(repeating: 1, count: 64).count }
        try #require((control ?? 0) > 0, "malloc_logger saw no allocation on this thread: the probe cannot measure here")

        let baseline = try #require(allocations { _ in })
        let frames = allocations { seq in
            rig.call(.frameBegin, seq: seq)
            rig.call(.frameEnd, seq: seq)
            rig.call(.contentsHandoff, seq: seq)
            rig.call(.gpuDone, seq: seq)
        }
        #expect(frames == baseline, "the loop alone made \(baseline)")
        #expect(trace.stubRecordCount.load(ordering: .relaxed) > 0, "the frames were recorded")
    }
}

/// Counts the allocations one thread makes, through libmalloc's `malloc_logger` hook (the one malloc stack
/// logging uses).
private nonisolated struct MallocProbe {
    typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    /// `MALLOC_LOG_TYPE_ALLOCATE` (libmalloc stack_logging.h).
    static let allocateType: UInt32 = 2
    static let count = Atomic<Int>(0)
    static let thread = Atomic<UInt64>(0)

    /// The allocations `body` makes on this thread, or nil when the hook is missing.
    static func allocations(_ body: () -> Void) -> Int? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
        let slot = symbol.assumingMemoryBound(to: Logger?.self)
        var id: UInt64 = 0
        pthread_threadid_np(nil, &id)
        count.store(0, ordering: .relaxed)
        thread.store(id, ordering: .relaxed)
        let previous = slot.pointee
        slot.pointee = { type, _, _, _, _, _ in
            guard type & MallocProbe.allocateType != 0 else { return }
            var id: UInt64 = 0
            pthread_threadid_np(nil, &id)
            if id == MallocProbe.thread.load(ordering: .relaxed) { _ = MallocProbe.count.wrappingAdd(1, ordering: .relaxed) }
        }
        body()
        slot.pointee = previous
        thread.store(0, ordering: .relaxed)
        return count.load(ordering: .relaxed)
    }
}
