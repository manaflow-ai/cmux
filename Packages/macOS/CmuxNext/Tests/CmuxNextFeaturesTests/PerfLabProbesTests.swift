#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextFeatures
import Testing

/// The perf lab canary's key-dispatch spin and the launch report of the two perf lab features
/// (`perfLabCanary`, `perfLabKillProbe`; plans/cmux-next/chrome-parity/p12-perf-process.md 3.7, 3.9).
struct PerfLabProbesTests {
    @Test func spinHoldsTheCallerForTheWholeTwoMilliseconds() {
        let clock = ContinuousClock()
        let start = clock.now
        let stopped = PerfLabKeySpin(clock: clock).spin()
        #expect(stopped - start >= .milliseconds(2))
        // A spin that slept or waited for a run loop would come back much later than its step.
        #expect(clock.now - start < .seconds(1))
    }

    @Test func spinStopsAtTheFirstReadingPastItsDuration() {
        let clock = ContinuousClock()
        let start = clock.now
        let stopped = PerfLabKeySpin(clock: clock, duration: .microseconds(300)).spin()
        #expect(stopped - start >= .microseconds(300))
        #expect(stopped <= clock.now)
    }

    @Test func zeroDurationReturnsAtOnce() {
        let clock = ContinuousClock()
        let start = clock.now
        #expect(PerfLabKeySpin(clock: clock, duration: .zero).spin() >= start)
    }

    @Test func delayingSpinsBeforeEveryDispatchAndKeepsItsAnswer() {
        let clock = ContinuousClock()
        var calls: [(Int, String, Duration)] = []
        let start = clock.now
        let dispatch = PerfLabKeySpin(clock: clock).delaying { (key: Int, window: String) -> Bool in
            calls.append((key, window, clock.now - start))
            return key.isMultiple(of: 2)
        }
        #expect(dispatch(2, "a") == true)
        #expect(dispatch(3, "b") == false)
        #expect(calls.map { $0.0 } == [2, 3])
        #expect(calls.map { $0.1 } == ["a", "b"])
        #expect(calls[0].2 >= .milliseconds(2))
        #expect(calls[1].2 >= .milliseconds(4))
    }

    @Test func killProbeIsOnAndCanaryOffByDefaultOnEveryChannel() {
        for channel in Feature.Channel.allCases {
            let report = PerfLabFeatureReport(FeatureList(registry: FeatureRegistry(), channel: channel))
            #expect(report.killProbe == Feature.Resolution(isEnabled: true, source: .channelDefault))
            #expect(report.canary == Feature.Resolution(isEnabled: false, source: .channelDefault))
        }
    }

    @Test func killProbeIsAStickyKillSwitch() {
        #expect(Feature.perfLabKillProbe.kind == .killSwitch)
        #expect(Feature.perfLabKillProbe.sticky)
        #expect(!Feature.perfLabCanary.sticky)
    }

    @Test func reportShowsARemoteKillOfTheProbe() {
        let features = FeatureList(registry: FeatureRegistry(), channel: .dev,
                                   overrides: FeatureOverrides(remote: ["perfLabKillProbe": false]))
        let report = PerfLabFeatureReport(features)
        #expect(report.killProbe == Feature.Resolution(isEnabled: false, source: .remote))
        #expect(report.line == "perf lab: perfLabCanary=off source=default perfLabKillProbe=off source=remote")
    }

    @Test func canaryTurnsOnFromTheEnvironment() {
        let features = FeatureList(registry: FeatureRegistry(), channel: .release,
                                   overrides: FeatureOverrides(environment: ["CMUX_ENABLE_FEATURES": "perfLabCanary"]))
        #expect(PerfLabFeatureReport(features).canary == Feature.Resolution(isEnabled: true, source: .environment))
    }
}
#endif
