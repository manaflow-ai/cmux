#if os(iOS)
import CmuxMobileDesign
import Foundation
import Testing

/// Leo, 2026-11-16: "it took like 7 seconds to reconnect or whatever to this chat on ios and it
/// said "Not connected"'at the top but i dont think it shoildve said anything".
///
/// The banner over Workspaces and chats (`LiveCoordinator.phaseChanged`): a link coming up or
/// coming back shows nothing inside the shared 10 s bound (first connect and reconnect alike), and
/// when it is back the banner just goes, with no "Connected" (audit 20, ceremony; Leo, 2026-11-18:
/// "All 4 do em these didn't need my addl input"). Measured on an injected clock: how long a
/// banner is on screen in each case, with the old policy (no hold, a "Connected" flash) and the new one.
@MainActor
@Suite struct BannerHoldTests {
    /// Replays `phaseChanged`'s banner rule for one outage of `outage` on `clock`, and returns
    /// how long any banner was on screen, in ms, until 3 s after the link is back.
    private func exposure(outage: Duration, firstConnect: Bool, held: Bool) async -> Int {
        let clock = LinkTestClock()
        defer { clock.stop() }
        let screen = Screen()
        let notice = HeldNotice<ConnectionBannerState>(clock: clock) { value in
            screen.saw(value, at: clock.now)
        }
        var flash: Task<Void, Never>?
        let state: ConnectionBannerState = firstConnect ? .connecting(to: "Mac") : .reconnecting(to: "Mac")
        let delay: Duration = held ? QuietStatusGate.threshold : .zero
        notice.hold(state, for: delay)
        await advance(clock, by: outage)
        // The old rule flashed "Connected" for 1.5 s after any reconnect banner; now the
        // banner just goes.
        if !held, !firstConnect, let shown = notice.shown, shown != .connected {
            notice.show(.connected)
            flash = Task { [clock] in
                do { try await clock.sleep(for: .milliseconds(1500)) } catch { return }
                notice.show(nil)
            }
        } else {
            notice.show(nil)
        }
        await advance(clock, by: .seconds(3))
        _ = flash
        screen.saw(nil, at: clock.now)
        return Int(screen.total.components.seconds * 1000 + screen.total.components.attoseconds / 1_000_000_000_000_000)
    }

    /// How long a banner was on screen, from the slot's changes.
    @MainActor private final class Screen {
        var since: LinkTestClock.Instant?
        var total = Duration.zero
        func saw(_ value: ConnectionBannerState?, at now: LinkTestClock.Instant) {
            if value != nil, since == nil { since = now }
            if value == nil, let start = since { total += start.duration(to: now); since = nil }
        }
    }

    /// Moves the clock in 100 ms steps, letting woken tasks run between steps.
    private func advance(_ clock: LinkTestClock, by duration: Duration) async {
        var left = duration
        while left > .zero {
            let step = min(left, .milliseconds(100))
            for _ in 0..<20 { await Task.yield() }
            clock.advance(by: step)
            left -= step
            for _ in 0..<20 { await Task.yield() }
        }
    }

    @Test func aFirstConnectUnderASecondShowsNothing() async {
        #expect(await exposure(outage: .milliseconds(800), firstConnect: true, held: false) == 800, "before")
        #expect(await exposure(outage: .milliseconds(800), firstConnect: true, held: true) == 0)
    }

    @Test func aSlowFirstConnectInsideTheBoundShowsNothing() async {
        #expect(await exposure(outage: .seconds(5), firstConnect: true, held: false) == 5000, "before")
        #expect(await exposure(outage: .seconds(5), firstConnect: true, held: true) == 0)
    }

    @Test func aReconnectUnderTenSecondsShowsNothing() async {
        // Before: "Reconnecting…" for the whole 7 s, then "Connected" for 1.5 s.
        #expect(await exposure(outage: .seconds(7), firstConnect: false, held: false) == 8500, "before")
        #expect(await exposure(outage: .seconds(7), firstConnect: false, held: true) == 0)
    }

    @Test func aLongOutageStillSaysSoAfterTheBound() async {
        // 12 s down: shown from 10 s until the link is back; no "Connected" after.
        #expect(await exposure(outage: .seconds(12), firstConnect: false, held: true) == 2000)
    }

    @Test func aRetryInsideTheWaitDoesNotRestartIt() async {
        let clock = LinkTestClock()
        defer { clock.stop() }
        let notice = HeldNotice<ConnectionBannerState>(clock: clock)
        notice.hold(.reconnecting(to: "Mac"), for: .seconds(10))
        await advance(clock, by: .seconds(6))
        notice.hold(.reconnecting(to: "Mac"), for: .seconds(10))
        #expect(notice.shown == nil)
        await advance(clock, by: .seconds(4))
        #expect(notice.shown == .reconnecting(to: "Mac"), "the first instant counts")
    }

    @Test func aStateWithAnActionShowsAtOnce() async {
        let clock = LinkTestClock()
        defer { clock.stop() }
        let notice = HeldNotice<ConnectionBannerState>(clock: clock)
        notice.hold(.reconnecting(to: "Mac"), for: .seconds(10))
        notice.show(.macOffline("Mac"))
        #expect(notice.shown == .macOffline("Mac"))
        await advance(clock, by: .seconds(11))
        #expect(notice.shown == .macOffline("Mac"), "the cancelled hold never replaces it")
    }
}
#endif
