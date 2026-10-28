import CmuxNextMetrics
import CmuxNextTrace
import Foundation
import Testing
@testable import CmuxNextWakeups

/// `key.echo_frame` from synthetic marks: one key in 16 opens an echo sample while none is
/// open, its echo's contents mark records the key-down-to-frame time for its surface's route, and a sample that
/// cannot show an echo closes at its commit. Main-actor tests, so the probe's run-loop commit observer never fires
/// in the middle of one.
@MainActor
struct TypingLatencyProbeEchoFrameTests {
    private static let profile = MetricsProfile(appVersion: "1.0", buildNumber: "1", channel: "dev", osVersion: "26.1.0",
                                                hardwareClass: "Mac16,10",
                                                buildDay: MetricsProfile.Day(year: 2026, month: 10, day: 26))

    /// A probe that samples echo frames into a fresh store on its own runtime.
    private static func sampler() -> (probe: TypingLatencyProbe, store: MetricsStore, trace: TraceRuntime) {
        let trace = TraceRuntime(role: .app)
        let store = MetricsStore(role: .app, profile: profile)
        store.attach(to: trace)
        let probe = TypingLatencyProbe(path: nil, trace: trace, echoFrames: Metrics(runtime: trace))
        probe.startEchoSampling()
        return (probe, store, trace)
    }

    private static func histogram(_ id: HistogramID, in store: MetricsStore) -> MetricsDelta.Histogram? {
        store.delta().histograms.first { $0.name == id.name }
    }

    /// The probe's open presses.
    private static func openCount(_ probe: TypingLatencyProbe) -> Int {
        probe.state.withLock { $0.open.count }
    }

    /// `count` key-downs the sampler does not take; each one must open nothing.
    private static func unsampledKeys(_ probe: TypingLatencyProbe, _ count: Int) {
        for _ in 0..<count {
            #expect(!probe.keyDown(eventTimestamp: 0))
        }
    }

    /// The newest press reaches `surface` and Ghostty takes it.
    private static func dispatchToTerminal(_ probe: TypingLatencyProbe, _ surface: TypingLatencyProbe.SurfaceKey) {
        probe.keyReachedTerminal(surface)
        probe.terminalTookKey()
        probe.mark(.dispatchEnd)
    }

    /// The press on `surface` is written, sent, echoed and parsed; returns its flow.
    private static func echoParsed(_ probe: TypingLatencyProbe, on surface: TypingLatencyProbe.SurfaceKey) throws -> UInt64 {
        probe.inputWritten(on: surface)
        let flow = try #require(probe.openFlow)
        probe.mark(.socketSubmit, flow: flow)
        probe.outputDecoded(flow: flow)
        probe.mark(.outputReceived, flow: flow)
        probe.mark(.outputParsed, flow: flow)
        return flow
    }

    @Test("The 16th key opens the echo sample; its echo's frame records key.echo_frame for the surface's route")
    func theSixteenthKeyRecordsItsEchoFrame() throws {
        let (probe, store, _) = Self.sampler()
        let surface = probe.makeSurfaceKey(route: .bridge)
        #expect(probe.samplesEchoFrames)
        Self.unsampledKeys(probe, Int(TypingLatencyProbe.echoSampleInterval) - 1)
        #expect(!probe.isRecording && Self.openCount(probe) == 0)

        #expect(probe.keyDown(eventTimestamp: ProcessInfo.processInfo.systemUptime - 0.004), "the key-down was 4 ms ago")
        #expect(probe.isRecording)
        Self.dispatchToTerminal(probe, surface)
        probe.inputWritten(on: surface)
        let flow = try #require(probe.openFlow)
        probe.mark(.socketSubmit, flow: flow)
        probe.outputDecoded(flow: flow)
        probe.mark(.outputReceived, flow: flow)
        probe.mark(.contents, surface: surface)
        #expect(probe.isRecording, "a frame before the echo was parsed (a cursor blink) does not end the sample")
        #expect(Self.histogram(.keyEchoFrame(.bridge), in: store) == nil)

        probe.mark(.outputParsed, flow: flow)
        probe.mark(.contents, surface: surface)
        #expect(!probe.isRecording, "the probe is off again")
        let echo = try #require(Self.histogram(.keyEchoFrame(.bridge), in: store))
        #expect(echo.count == 1)
        #expect(echo.sum >= 4_000 && echo.sum < 60_000_000, "key-down to the contents mark, in us")
        #expect(Self.histogram(.keyEchoFrame(.local), in: store) == nil)
    }

    @Test("Keys while the sample is open do not count; the next sample is due 16 keys after it closes")
    func keysCountOnlyWhileNoSampleIsOpen() throws {
        let (probe, store, _) = Self.sampler()
        let surface = probe.makeSurfaceKey()
        Self.unsampledKeys(probe, 15)
        #expect(probe.keyDown(eventTimestamp: 0))
        Self.dispatchToTerminal(probe, surface)
        for _ in 0..<20 {
            #expect(probe.keyDown(eventTimestamp: 0), "while the sample is open the probe records every key")
            probe.mark(.dispatchEnd)
            probe.turnDidEnd() // the key went to no terminal: its commit closes it
        }
        #expect(Self.openCount(probe) == 1, "only the sampled press is left")
        _ = try Self.echoParsed(probe, on: surface)
        probe.mark(.contents, surface: surface)
        #expect(Self.histogram(.keyEchoFrame(.local), in: store)?.count == 1)

        Self.unsampledKeys(probe, 15)
        #expect(probe.keyDown(eventTimestamp: 0), "the 16th key after the sample closed")
        #expect(probe.isRecording)
    }

    @Test("A sampled key that reaches no terminal closes at its commit and records nothing")
    func aKeyToATextViewClosesAtItsCommit() {
        let (probe, store, _) = Self.sampler()
        Self.unsampledKeys(probe, 15)
        #expect(probe.keyDown(eventTimestamp: 0))
        probe.mark(.dispatchEnd)
        probe.turnDidEnd()
        #expect(!probe.isRecording && Self.openCount(probe) == 0)
        #expect(store.delta().isEmpty)
        Self.unsampledKeys(probe, 15)
        #expect(probe.keyDown(eventTimestamp: 0), "sampling goes on")
    }

    @Test("A sampled key Ghostty took no bytes from closes at its commit")
    func aKeyWithNoBytesClosesAtItsCommit() {
        let (probe, store, _) = Self.sampler()
        let surface = probe.makeSurfaceKey()
        Self.unsampledKeys(probe, 15)
        #expect(probe.keyDown(eventTimestamp: 0))
        probe.keyReachedTerminal(surface)
        probe.mark(.dispatchEnd)
        probe.turnDidEnd()
        #expect(!probe.isRecording && Self.openCount(probe) == 0)
        #expect(store.delta().isEmpty)
    }

    @Test("A sampled key that echoes nothing does not take an output decoded 2 s later, named or not")
    func aLateOutputIsNotTheSampledKeysEcho() throws {
        for exact in [true, false] {
            let (probe, store, _) = Self.sampler()
            let surface = probe.makeSurfaceKey()
            Self.unsampledKeys(probe, 15)
            #expect(probe.keyDown(eventTimestamp: ProcessInfo.processInfo.systemUptime - 2), "the key-down was 2 s ago")
            Self.dispatchToTerminal(probe, surface)
            probe.inputWritten(on: surface)
            let flow = try #require(probe.openFlow)
            probe.mark(.socketSubmit, flow: flow)
            probe.turnDidEnd()
            #expect(probe.isRecording, "exact \(exact): the written key waits for its echo")

            // The next output on the surface is a redraw 2 s later; the daemon's slot still names the key.
            probe.outputDecoded(flow: exact ? flow : nil)
            probe.mark(.outputReceived, flow: flow)
            probe.mark(.outputReceived, surface: surface)
            probe.mark(.outputParsed, flow: flow)
            probe.mark(.outputParsed, surface: surface)
            probe.mark(.contents, surface: surface)
            #expect(Self.histogram(.keyEchoFrame(.local), in: store) == nil, "exact \(exact)")
            #expect(!probe.isRecording && Self.openCount(probe) == 0, "exact \(exact): the sample was dropped")
            Self.unsampledKeys(probe, 15)
            #expect(probe.keyDown(eventTimestamp: 0), "exact \(exact): sampling goes on")
        }
    }

    @Test("A newer press written on the sample's surface before its echo is decoded drops the sample")
    func aNewerWriteOnTheSurfaceDropsTheSample() throws {
        let (probe, store, _) = Self.sampler()
        let surface = probe.makeSurfaceKey(), other = probe.makeSurfaceKey()
        Self.unsampledKeys(probe, 15)
        #expect(probe.keyDown(eventTimestamp: 0))
        Self.dispatchToTerminal(probe, surface)
        probe.inputWritten(on: surface)
        let flow = try #require(probe.openFlow)
        probe.mark(.socketSubmit, flow: flow)

        #expect(probe.keyDown(eventTimestamp: 0))
        Self.dispatchToTerminal(probe, other)
        probe.inputWritten(on: other)
        #expect(probe.isRecording, "a write on another surface leaves the sample open")

        #expect(probe.keyDown(eventTimestamp: 0))
        Self.dispatchToTerminal(probe, surface)
        probe.inputWritten(on: surface)
        #expect(!probe.isRecording && Self.openCount(probe) == 0, "the newer press holds the daemon's slot now")

        probe.outputDecoded(flow: flow)
        probe.mark(.outputReceived, flow: flow)
        probe.mark(.outputParsed, flow: flow)
        probe.mark(.contents, surface: surface)
        #expect(store.delta().isEmpty)
    }

    @Test("When the sample closes, presses opened beside it go too, unless key flows are on")
    func theSampleClosesAloneOnlyWhileFlowsRecord() throws {
        for flows in [false, true] {
            let (probe, _, _) = Self.sampler()
            if flows { probe.startFlows() }
            let surface = probe.makeSurfaceKey(), other = probe.makeSurfaceKey()
            Self.unsampledKeys(probe, flows ? 0 : 15)
            if flows {
                for _ in 0..<15 {
                    #expect(probe.keyDown(eventTimestamp: 0))
                    probe.mark(.dispatchEnd)
                }
                probe.turnDidEnd()
            }
            #expect(probe.keyDown(eventTimestamp: 0))
            Self.dispatchToTerminal(probe, surface)
            #expect(probe.keyDown(eventTimestamp: 0))
            Self.dispatchToTerminal(probe, other)
            _ = try Self.echoParsed(probe, on: surface)
            probe.mark(.contents, surface: surface)
            #expect(Self.openCount(probe) == (flows ? 1 : 0), "flows \(flows)")
            #expect(probe.isRecording == flows)
        }
    }

    @Test("With echo sampling off or not started, no store, or the keystroke-timing gate closed, no key opens a sample")
    func nothingSamplesWhenOff() {
        let off = TypingLatencyProbe(path: nil, trace: TraceRuntime(role: .app))
        off.startEchoSampling()
        #expect(!off.samplesEchoFrames, "a probe made without echo frames never samples")
        Self.unsampledKeys(off, 64)

        let unstartedTrace = TraceRuntime(role: .app)
        MetricsStore(role: .app, profile: Self.profile).attach(to: unstartedTrace)
        let unstarted = TypingLatencyProbe(path: nil, trace: unstartedTrace, echoFrames: Metrics(runtime: unstartedTrace))
        #expect(!unstarted.samplesEchoFrames, "nothing that ends a sample started it")
        Self.unsampledKeys(unstarted, 64)

        let storeless = TraceRuntime(role: .app)
        let noStore = TypingLatencyProbe(path: nil, trace: storeless, echoFrames: Metrics(runtime: storeless))
        noStore.startEchoSampling()
        Self.unsampledKeys(noStore, 64)
        #expect(!noStore.isRecording)

        let (gated, store, trace) = Self.sampler()
        trace.setKeyTimingSuppressed(true, by: .terminalSecureInput)
        Self.unsampledKeys(gated, 64)
        #expect(!gated.isRecording && store.delta().isEmpty)
    }
}
