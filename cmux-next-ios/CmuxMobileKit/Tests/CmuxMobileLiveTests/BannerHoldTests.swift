#if os(iOS)
import CmuxMobileDesign
import Foundation
import Testing

/// Leo, 2026-11-16: "it took like 7 seconds to reconnect or whatever to this chat on ios and it
/// said "Not connected"'at the top but i dont think it shoildve said anything".
///
/// The banner over Workspaces and chats (`LiveCoordinator.phaseChanged`): a link coming up or
/// coming back shows nothing inside the shared 10 s bound (first connect and reconnect alike), and
/// coming back never flashes "Connected". Measured on an injected clock: how long a banner is on
/// screen in each case, with the old policy (shown at once, then "Connected" for 1.5 s) and the new
/// one (held, then gone the moment the link is back).
///
/// Leo, 2026-11-23: "i dont wanna see reconnecting to the Mac in a toast, i want it to just connect."
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
        let delay: Duration = held ? QuietStatusGate.threshold : .zero
        notice.hold(.connectionFailed, for: delay)
        await advance(clock, by: outage)
        // .connected: the old rule flashed "Connected" for 1.5 s after any reconnect banner,
        // which showed at once; the new one clears the slot.
        if !held, !firstConnect {
            notice.show(Self.oldConnectedToast)
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

    /// The old 1.5 s "Connected" toast (the state is gone; only the old policy's replay draws it).
    private static let oldConnectedToast = ConnectionBannerState.failed("Connected")

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
        // 12 s down: the one chip from 10 s, gone the moment the link is back (no "Connected").
        #expect(await exposure(outage: .seconds(12), firstConnect: false, held: true) == 2000)
    }

    /// The time from a link drop to a visible Reconnecting chip, on an injected clock: the
    /// coordinator holds the state for the bound (``HeldNotice``), then the banner draws it as
    /// a chip whose own quiet gate (``QuietStatusGate``) counts from `countsFromDrop` ? the link's
    /// drop : the moment the chip appeared (cmux#51275 as merged, the review's finding).
    private func timeToChip(countsFromDrop: Bool) async -> Duration {
        let clock = LinkTestClock()
        defer { clock.stop() }
        let drop = clock.now
        let notice = HeldNotice<ConnectionBannerState>(clock: clock)
        notice.hold(.reconnecting(to: "Mac"), for: QuietStatusGate.threshold)
        var gate: QuietStatusGate?
        while clock.now.offset < .seconds(40) {
            if gate == nil, notice.shown != nil {
                let chip = QuietStatusGate(clock: clock)
                chip.update(down: true, alreadyDownFor: countsFromDrop ? drop.duration(to: clock.now) : .zero)
                gate = chip
            }
            if gate?.isShown == true { return drop.duration(to: clock.now) }
            await advance(clock, by: .milliseconds(100))
        }
        return .seconds(40)
    }

    @Test func aReconnectingChipShowsTenSecondsAfterTheDropNotTwenty() async {
        let before = await timeToChip(countsFromDrop: false)
        let after = await timeToChip(countsFromDrop: true)
        print("time-to-chip (injected clock, idle fixture): before \(before), after \(after)")
        #expect(before == QuietStatusGate.threshold * 2, "the double hold this fixes")
        #expect(after == QuietStatusGate.threshold, "zero extra wait after the coordinator's hold")
    }

    @Test func aRetryInsideTheWaitDoesNotRestartIt() async {
        let clock = LinkTestClock()
        defer { clock.stop() }
        let notice = HeldNotice<ConnectionBannerState>(clock: clock)
        notice.hold(.connectionFailed, for: .seconds(10))
        await advance(clock, by: .seconds(6))
        notice.hold(.connectionFailed, for: .seconds(10))
        #expect(notice.shown == nil)
        await advance(clock, by: .seconds(4))
        #expect(notice.shown == .connectionFailed, "the first instant counts")
    }

    @Test func aStateWithAnActionShowsAtOnce() async {
        let clock = LinkTestClock()
        defer { clock.stop() }
        let notice = HeldNotice<ConnectionBannerState>(clock: clock)
        notice.hold(.connectionFailed, for: .seconds(10))
        notice.show(.macOffline("Mac"))
        #expect(notice.shown == .macOffline("Mac"))
        await advance(clock, by: .seconds(11))
        #expect(notice.shown == .macOffline("Mac"), "the cancelled hold never replaces it")
    }
}
#endif
