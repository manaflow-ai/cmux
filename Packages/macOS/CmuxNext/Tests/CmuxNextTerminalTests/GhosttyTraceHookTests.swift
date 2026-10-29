import CmuxNextCompat
import CoreGraphics
@testable import CmuxNextDesign
import CmuxNextMetrics
@testable import CmuxNextSignposts
@testable import CmuxNextTerminal
@testable import CmuxNextTrace
@testable import CmuxNextWakeups
import Darwin
import Dispatch
import GhosttyNextKit
import QuartzCore
import Testing

/// The Ghostty trace hook against ghostty-next's 048 ABI (ghostty.h): `ghostty.render`
/// around a draw, `frame.gpu_done` at its GPU completion, a frame's first `CONTENTS_SET` as the echo stages'
/// frame and the typing probe's contents mark, the GPU completion of a frame handed over before it, surfaces
/// found by trace id only, and the record installed only while something reads it. A test calls the hook the
/// way ghostty-next does: through the installed record's `ctx`, with the header's event values, only while
/// the record is installed.
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
        func count(_ name: String) -> Int { hops.withLock { $0.filter { $0.0 == name }.count } }
        func gpuFinished(_ flow: UInt64) { gpu.withLock { $0.append(flow) } }
        var gpuFlows: [UInt64] { gpu.withLock { $0 } }
    }

    /// What the stand-in for `ghostty_set_trace_hook` was last given.
    final class Installed {
        var isOn = false
        var calls = 0
    }

    nonisolated static let allCategories = SignpostCategory.allCases.reduce(UInt64(0)) { $0 | 1 << UInt64($1.traceBit) }
    /// Runs a posted body at once: the tests call from the main thread.
    nonisolated static let atOnce: @Sendable (_ body: @escaping @MainActor @Sendable () -> Void) -> Void = { body in
        MainActor.assumeIsolated { body() }
    }

    /// A hook on `trace` and `probe` with one registered surface. With `heard`, GPU completions go to it at once.
    struct Rig {
        let hook: GhosttyTraceHook
        let installed: Installed
        let bridge: SurfaceBridge
        let key: TypingLatencyProbe.SurfaceKey
        /// The surface's `ghostty_surface_trace_id`.
        let id: UInt64 = 41

        init(trace: TraceRuntime, probe: TypingLatencyProbe, heard: Heard? = nil, gate: TerminalContentsGate = TerminalContentsGate(),
             echoStage: TerminalEchoStage? = nil) {
            let installed = Installed()
            hook = GhosttyTraceHook(gate: gate, trace: trace, probe: probe, linkage: .custom({ on in
                installed.isOn = on
                installed.calls += 1
            }))
            if let heard {
                hook.recorder.deliverGPU(GhosttyTraceHook.GPUDelivery(post: GhosttyTraceHookTests.atOnce,
                                                                      finished: { flow, _ in heard.gpuFinished(flow) }))
            }
            self.installed = installed
            key = probe.makeSurfaceKey()
            // The surface's input goes nowhere: these tests read only the trace hook.
            let lane = TerminalInputLane(drain: TerminalInputDrain(queue: DispatchQueue(label: "GhosttyTraceHookTests.input", qos: .utility)) { _, _ in .next })
            bridge = SurfaceBridge(input: TerminalInputSink(lane: lane, typingSurface: key), echoStage: echoStage,
                                   frameMarks: hook.recorder)
            _ = hook.register(bridge.frames, id: id)
        }

        /// Calls the surface's `presented_cb` as the renderer does for frame `frameID`; `presentedTime` 0: not shown.
        func present(frameID: UInt64, presentedTime: Double = 1) {
            ghosttySurfacePresented(Unmanaged.passUnretained(bridge).toOpaque(), frameID, mach_absolute_time(), presentedTime)
        }

        /// Calls the installed record as Ghostty does for surface `surface` (this rig's by default).
        func call(_ event: GhosttyTraceHook.Event, seq: UInt64, surface: UInt64? = nil) {
            guard installed.isOn else { return }
            GhosttyTraceHook.Recorder.receive(context: hook.context, event, surface: surface ?? id, seq: seq)
        }
    }

    /// One key press on `key` whose echo was parsed; returns its flow.
    static func parsedPress(_ probe: TypingLatencyProbe, on key: TypingLatencyProbe.SurfaceKey) throws -> UInt64 {
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

    @Test func theEventValuesAreGhosttyHs() {
        let events: [(UInt32, GhosttyTraceHook.Event)] = [(0, .frameBegin), (1, .frameEnd), (2, .contentsSet),
                                                          (3, .gpuDone), (4, .ioWrite), (5, .surfaceDestroy)]
        for (value, event) in events { #expect(GhosttyTraceHook.Event(rawValue: value) == event) }
        #expect(GhosttyTraceHook.Event(rawValue: 6) == nil)
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
        rig.call(.frameEnd, seq: 0) // an end with no begin written writes nothing

        let records = log.records
        #expect(records.map(\.name) == [SignpostName.ghosttyRender.rawValue, SignpostName.ghosttyRender.rawValue,
                                        SignpostName.frameGPUDone.rawValue])
        #expect(records.map(\.phase) == [.begin, .end, .instant])
        #expect(records.allSatisfy { $0.arg0 == rig.key.traceID })
        #expect(records.first?.arg1 == 0, "no press waits for this frame")
        #expect(records.last?.arg1 == 1, "frame.gpu_done names its frame's seq")
    }

    /// A call names its surface by trace id only: an id the hook never registered, or one unregistered after
    /// `ghostty_surface_free` (a present queued before free that lands after it), records nothing.
    @Test func callsForAnUntrackedSurfaceRecordNothing() throws {
        let log = RecordLog()
        let trace = log.runtime()
        let probe = TypingLatencyProbe(path: nil, trace: trace)
        probe.startFlows()
        defer { probe.stopFlows() }
        let rig = Rig(trace: trace, probe: probe)
        rig.hook.refreshDemand()
        _ = try Self.parsedPress(probe, on: rig.key)
        let beforeUntracked = log.records.count // the press's key.flow hops

        rig.call(.frameBegin, seq: 1, surface: rig.id + 1)
        rig.call(.gpuDone, seq: 1, surface: 0)
        #expect(log.records.count == beforeUntracked)

        rig.call(.frameBegin, seq: 1)
        rig.call(.surfaceDestroy, seq: 0) // closes the open slice
        rig.hook.unregister(id: rig.id)
        let written = log.records.count
        rig.call(.contentsSet, seq: 1)
        rig.call(.gpuDone, seq: 1)
        #expect(log.records.count == written)
        probe.turnDidEnd()
        #expect(probe.takePresentCommits().isEmpty, "a contents_set after free marks no press")
    }

    @Test func theHandoffMarksTheParsedPressAndItsPresentWaitsForTheGPU() throws {
        let log = RecordLog(), heard = Heard()
        let trace = log.runtime()
        let probe = TypingLatencyProbe(path: nil, trace: trace, hopRecorder: { heard.hop($0, $1) })
        probe.startFlows()
        defer { probe.stopFlows() }
        let rig = Rig(trace: trace, probe: probe, heard: heard)
        rig.hook.refreshDemand()
        let flow = try Self.parsedPress(probe, on: rig.key)

        rig.call(.frameBegin, seq: 1)
        #expect(log.records.last?.arg1 == flow, "ghostty.render names the press whose echo it draws")
        rig.call(.frameEnd, seq: 1)
        rig.call(.contentsSet, seq: 1)
        #expect(heard.has("app.frame.contents", flow))
        probe.turnDidEnd()
        #expect(probe.takePresentCommits() == [FramePresentEstimate.Commit(flow: flow, display: 7, awaitsGPU: true)])
        #expect(heard.gpuFlows.isEmpty)

        rig.call(.gpuDone, seq: 1)
        #expect(heard.gpuFlows == [flow], "the GPU completion goes to the presents once")
        rig.call(.gpuDone, seq: 2)
        #expect(heard.gpuFlows == [flow])
    }

    /// A host-size change can report one frame twice: only the first report marks.
    @Test func aFrameReportedTwiceIsMarkedOnce() throws {
        let heard = Heard()
        let trace = RecordLog().runtime()
        let probe = TypingLatencyProbe(path: nil, trace: trace, hopRecorder: { heard.hop($0, $1) })
        probe.startFlows()
        defer { probe.stopFlows() }
        let rig = Rig(trace: trace, probe: probe)
        rig.hook.refreshDemand()
        let first = try Self.parsedPress(probe, on: rig.key)
        rig.call(.contentsSet, seq: 1)
        let second = try Self.parsedPress(probe, on: rig.key)

        rig.call(.contentsSet, seq: 1)
        #expect(!heard.has("app.frame.contents", second), "the frame drawn before the second echo does not show it")
        rig.call(.contentsSet, seq: 2)
        #expect(heard.has("app.frame.contents", first) && heard.has("app.frame.contents", second))
        #expect(heard.count("app.frame.contents") == 2)
    }

    /// Until the app gives the hook its presents, an echo commit never waits for a GPU completion nobody delivers.
    @Test func withNoDeliveryTheCommitDoesNotWaitForTheGPU() throws {
        let trace = RecordLog().runtime()
        let probe = TypingLatencyProbe(path: nil, trace: trace)
        probe.startFlows()
        defer { probe.stopFlows() }
        let rig = Rig(trace: trace, probe: probe)
        rig.hook.refreshDemand()
        let flow = try Self.parsedPress(probe, on: rig.key)

        rig.call(.contentsSet, seq: 1)
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
        let flow = try Self.parsedPress(probe, on: rig.key)

        rig.call(.gpuDone, seq: 1)
        rig.call(.contentsSet, seq: 1)
        probe.turnDidEnd()
        #expect(probe.takePresentCommits() == [FramePresentEstimate.Commit(flow: flow, display: 7, awaitsGPU: false)])
        #expect(heard.gpuFlows.isEmpty)
    }

    /// More presses than the eight waits of the first version, closed by one frame: every one waits for the
    /// GPU and every one gets its completion.
    @Test func manyPressesClosedByOneHandoffAllGetTheirGPUCompletion() throws {
        let heard = Heard()
        let trace = RecordLog().runtime()
        let probe = TypingLatencyProbe(path: nil, trace: trace)
        probe.startFlows()
        defer { probe.stopFlows() }
        let rig = Rig(trace: trace, probe: probe, heard: heard)
        rig.hook.refreshDemand()
        let flows = try (0..<12).map { _ in try Self.parsedPress(probe, on: rig.key) }

        rig.call(.contentsSet, seq: 1)
        probe.turnDidEnd()
        let commits = probe.takePresentCommits()
        #expect(commits.map(\.flow).sorted() == flows.sorted())
        #expect(commits.allSatisfy { $0.awaitsGPU })
        rig.call(.gpuDone, seq: 1)
        #expect(heard.gpuFlows.sorted() == flows.sorted())
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

        rig.call(.contentsSet, seq: 1)
        #expect(stages.sink.events == [.echoParsed, .contentSubmitted])
        #expect(!stages.gate.isOpen)
    }

    #if !GHOSTTY_RENDERER_FRAMES
    nonisolated final class TraceHookFramesLayer: CALayer {}

    /// With a supported hook the layer swizzle of DEBUG and bench builds marks neither the echo stage nor the
    /// probe: the hook's `CONTENTS_SET` marks each flow once and keeps its GPU wait.
    @Test func withTheHookTheLayerSwizzleMarksNoFrame() throws {
        let heard = Heard()
        let stages = TerminalEchoStageTests.Rig()
        let trace = RecordLog().runtime()
        let probe = TypingLatencyProbe(path: nil, trace: trace, hopRecorder: { heard.hop($0, $1) })
        probe.startFlows()
        defer { probe.stopFlows() }
        let rig = Rig(trace: trace, probe: probe, heard: heard, gate: stages.gate, echoStage: stages.stage)
        rig.hook.echoStagesInstalled()
        let layer = TraceHookFramesLayer()
        TypingFrameProbe.install(on: layer, gate: stages.gate, keyFlows: rig.key, frames: .traceHook)
        stages.stage.attach(to: layer)
        let flow = try Self.parsedPress(probe, on: rig.key)
        try stages.key(at: 1_000)
        stages.echo()

        layer.contents = try Self.image()
        #expect(stages.sink.events == [.echoParsed], "the swizzle did not take the echo stage's frame")
        #expect(heard.count("app.frame.contents") == 0, "the swizzle did not take the probe's contents mark")

        rig.call(.contentsSet, seq: 1)
        #expect(stages.sink.events == [.echoParsed, .contentSubmitted])
        #expect(heard.count("app.frame.contents") == 1)
        probe.turnDidEnd()
        #expect(probe.takePresentCommits() == [FramePresentEstimate.Commit(flow: flow, display: 7, awaitsGPU: true)])
    }
    #endif

    /// With renderer-owned frames the renderer presents off main and reports each frame through
    /// the surface's `presented_cb`: that is the probe's contents mark, with no trace hook set, and a presented frame
    /// never waits for its GPU work. A frame that was not shown marks nothing.
    @Test func thePresentedFrameMarksTheParsedPressWithoutWaitingForTheGPU() throws {
        let heard = Heard()
        let trace = RecordLog().runtime()
        let probe = TypingLatencyProbe(path: nil, trace: trace, hopRecorder: { heard.hop($0, $1) })
        probe.startFlows()
        defer { probe.stopFlows() }
        let rig = Rig(trace: trace, probe: probe, heard: heard)
        let flow = try Self.parsedPress(probe, on: rig.key)

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
    /// A renderer-presented frame passes through no `setContents:` hook, so each shown one is a
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

    /// The Core Animation threads that report presented frames count them without a data race
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

    @Test func theHookIsInstalledOnlyWhileSomethingReadsIt() {
        let trace = TraceRuntime(role: .app)
        let rig = Rig(trace: trace, probe: TypingLatencyProbe(path: nil, trace: trace))
        rig.hook.refreshDemand()
        #expect(!rig.hook.isInstalled && rig.installed.calls == 0, "nothing reads it: the pointer stays null")

        trace.setCategoryMask(1 << UInt64(SignpostCategory.frame.traceBit))
        rig.hook.refreshDemand()
        #expect(rig.hook.isInstalled && rig.installed.isOn)
        rig.hook.refreshDemand()
        #expect(rig.installed.calls == 1, "a refresh that changes nothing does not set it again")

        let unsupported = GhosttyTraceHook(gate: TerminalContentsGate(), trace: trace, linkage: .unsupported)
        trace.setCategoryMask(Self.allCategories)
        unsupported.refreshDemand()
        #expect(!unsupported.isSupported && !unsupported.isInstalled)
    }

    /// The trace categories and the typing probe's flows set and clear the record through their observers,
    /// with no refresh call of their own (`trace.start`, `trace.stop` and a run-time flows start reach it).
    @Test func categoryChangesAndKeyFlowsInstallAndClearTheHook() {
        let trace = TraceRuntime(role: .app)
        let probe = TypingLatencyProbe(path: nil, trace: trace)
        let rig = Rig(trace: trace, probe: probe)
        rig.hook.followDemand(post: Self.atOnce)
        #expect(!rig.installed.isOn)

        trace.setCategoryMask(1 << UInt64(SignpostCategory.frame.traceBit))
        #expect(rig.installed.isOn, "trace.start of the frame category sets it")
        trace.setCategoryMask(0)
        #expect(!rig.installed.isOn, "trace.stop clears it")

        probe.startFlows()
        #expect(rig.installed.isOn, "key flows started at run time set it")
        probe.stopFlows()
        #expect(!rig.installed.isOn, "stopping them clears it")
        #expect(rig.installed.calls == 4)
    }

    /// The hook turns echo sampling on, sampling keeps the hook set with nothing recording,
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
        _ = try Self.parsedPress(probe, on: rig.key) // the 16th key
        rig.call(.contentsSet, seq: 1)
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
            rig.call(.contentsSet, seq: seq)
            rig.call(.gpuDone, seq: seq)
        }
        #expect(frames == baseline, "the loop alone made \(baseline)")
        #expect(trace.stubRecordCount.load(ordering: .relaxed) > 0, "the frames were recorded")
    }

    #if GHOSTTY_TRACE_HOOK
    /// libghostty's own record type and event constants reach the same recorder (ghostty.h, 048).
    @Test func libghosttysRecordAndEventsReachTheRecorder() {
        let log = RecordLog()
        let trace = log.runtime()
        let rig = Rig(trace: trace, probe: TypingLatencyProbe(path: nil, trace: trace))
        let record = ghostty_trace_hook_s(callback: ghosttyTraceHook, ctx: rig.hook.context)
        record.callback?(record.ctx, GHOSTTY_TRACE_FRAME_BEGIN, rig.id, 1)
        record.callback?(record.ctx, GHOSTTY_TRACE_FRAME_END, rig.id, 1)
        record.callback?(record.ctx, GHOSTTY_TRACE_GPU_DONE, rig.id, 1)
        #expect(log.records.map(\.phase) == [.begin, .end, .instant])
        #expect(GhosttyTraceHook.Event(GHOSTTY_TRACE_CONTENTS_SET) == .contentsSet)
        #expect(GhosttyTraceHook.Event(GHOSTTY_TRACE_IO_WRITE) == .ioWrite)
        #expect(GhosttyTraceHook.Event(GHOSTTY_TRACE_SURFACE_DESTROY) == .surfaceDestroy)
    }
    #endif

    private static func image() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return try #require(context.makeImage())
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
