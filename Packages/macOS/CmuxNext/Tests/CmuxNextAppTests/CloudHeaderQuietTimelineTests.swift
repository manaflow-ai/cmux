@testable import CmuxNextApp
@testable import CmuxNextSidebar
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// Leo, 2026-11-14: "i also want all our connectivity stuff to shut up and load faster/percievably load
/// faster". The Cloud machine header's connection chrome on a timeline: how many ms a person sees
/// words ("Resuming…", "Connecting…", "Reconnecting…") or a spinner in the header, through the grace
/// the bridge runs (`SidebarPlaceholderGrace.holdingConnectingLabels`, ``QuietHold/connectionDelay``),
/// on the manual clock. The PR's before/after table is this harness's `QUIET-CLOUD` lines.
@MainActor
struct CloudHeaderQuietTimelineTests {
    typealias Status = SidebarMachine.Status

    /// What the header says over `segments` (each status held for its length, then the next):
    /// the time words or a spinner show.
    static func exposure(_ segments: [(Status, Duration)], quietResume: Bool = true) async throws -> Duration {
        let clock = ManualClock()
        let grace = SidebarPlaceholderGrace(wait: SidebarPlaceholderGrace.connectingDelay, clock: clock)
        grace.quietConnectOverride = quietResume
        var exposed: Duration = .zero
        for (status, length) in segments {
            let section = SidebarSection(kind: .machine(SidebarMachine(id: MachineID("vm-cloud"), name: "Cloud", kind: .cloud, status: status)), nodes: [])
            var left = length
            while left > .zero {
                let header = try #require(grace.holdingConnectingLabels([section]).first?.machine)
                let drawn = SectionHeaderRowView.drawn(header)
                let says = SectionHeaderRowView.statusText(drawn.status, hostGroup: false) != nil
                    || SectionHeaderRowView.tone(drawn, hostGroup: false) == .working
                if header.holdsStatusLabel {
                    // The hold's timer sleeps on the clock: run to its end, or to the segment's end.
                    try await clock.waitForSleeper()
                    let end = try #require(clock.sleeperDeadlines.min())
                    let toEnd = clock.now.duration(to: end)
                    if toEnd <= left {
                        await withCheckedContinuation { (ended: CheckedContinuation<Void, Never>) in
                            grace.onEnd = { ended.resume() }
                            clock.advance(by: toEnd)
                        }
                        grace.onEnd = nil
                        left -= toEnd
                        continue
                    }
                }
                if says { exposed += left }
                clock.advance(by: left)
                left = .zero
            }
        }
        return exposed
    }

    static func ms(_ duration: Duration) -> Int {
        Int(duration.components.seconds) * 1000 + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }

    /// The scenarios of the table: a fast path (< 1 s), a short one (< 10 s), and a long one that
    /// may honestly say so after the hold.
    static let scenarios: [(name: String, segments: [(Status, Duration)])] = [
        ("cloud connect 0.8 s (launch)", [(.connecting, .milliseconds(800)), (.connected, .seconds(1))]),
        ("cloud reconnect 6 s", [(.connected, .seconds(1)), (.reconnecting, .seconds(6)), (.connected, .seconds(1))]),
        ("cloud resume from pause 0.8 s", [(.resuming, .milliseconds(700)), (.connecting, .milliseconds(100)), (.connected, .seconds(1))]),
        ("cloud resume from pause 6 s", [(.resuming, .seconds(5)), (.connecting, .seconds(1)), (.connected, .seconds(1))]),
        ("cloud resume from pause 15 s", [(.resuming, .seconds(14)), (.connecting, .seconds(1)), (.connected, .seconds(1))]),
    ]

    @Test func aCloudHeaderSaysNothingOnAFastOrShortConnect() async throws {
        var measured: [String: Int] = [:]
        for scenario in Self.scenarios {
            let before = Self.ms(try await Self.exposure(scenario.segments, quietResume: false))
            let shown = Self.ms(try await Self.exposure(scenario.segments))
            measured[scenario.name] = shown
            print("QUIET-CLOUD scenario=\"\(scenario.name)\" switch_off_ms=\(before) label_exposure_ms=\(shown)")
        }
        #expect(measured["cloud connect 0.8 s (launch)"] == 0)
        #expect(measured["cloud reconnect 6 s"] == 0)
        #expect(measured["cloud resume from pause 0.8 s"] == 0, "a fast resume flashed Resuming…")
        #expect(measured["cloud resume from pause 6 s"] == 0, "a resume under the hold said Resuming…")
        // A resume that lasts past the hold says so honestly from the hold on (15 s - 10 s).
        #expect(measured["cloud resume from pause 15 s"] == 5_000)
    }

    /// With Quiet Cloud Resume off (the default), a resume says "Resuming…" from its first frame, as
    /// before; the connect that follows is still held.
    @Test func withTheSwitchOffAResumeIsSaidAtOnce() async throws {
        let shown = Self.ms(try await Self.exposure([(.resuming, .seconds(5)), (.connecting, .seconds(1)), (.connected, .seconds(1))], quietResume: false))
        #expect(shown == 5_000)
    }

    /// A state a person must act on is said at once, never held.
    @Test func aFailedCloudMachineIsSaidAtOnce() async throws {
        let shown = Self.ms(try await Self.exposure([(.failed, .seconds(2))]))
        #expect(shown == 2_000)
    }
}
