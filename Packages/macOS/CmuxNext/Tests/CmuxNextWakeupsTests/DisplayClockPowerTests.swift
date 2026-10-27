import AppKit
import CmuxNextWakeupsTestSupport
@testable import CmuxNextWakeups
import QuartzCore
import Testing

/// The power caps on the display links (p03-rendering-117): while the injected ``PowerState`` caps
/// frames (Low Power Mode, a serious or critical thermal state) `.ambient` pauses, `.ui` caps at
/// 60 Hz and `.motion` is unchanged. Chrome reads the same inputs: the OS battery saver turns its
/// battery saver on (components/performance_manager/user_tuning/battery_saver_mode_manager.cc), and
/// `PowerThermalObserver::DeviceThermalState` (base/power_monitor/power_observer.h) reports the heat.
@MainActor @Suite(.timeLimit(.minutes(1))) struct DisplayClockPowerTests {
    /// What caps frames: Low Power Mode or a serious thermal state; a fair one does not.
    @Test func powerStateCapsInLowPowerModeAndSeriousHeat() {
        #expect(!PowerState.nominal.capsFrames)
        #expect(!PowerState(thermal: .fair).capsFrames)
        for state in PowerState.cappedExamples { #expect(state.capsFrames, "\(state)") }
        let capped = PowerState(lowPowerMode: true)
        #expect(capped.pauses(.ambient) && capped.pauses(.slow(4)))
        #expect(!capped.pauses(.ui) && !capped.pauses(.motion))
        #expect(!PowerState.nominal.pauses(.ambient))
    }

    /// `.ambient` pauses under the cap: the client stays active but leaves its scheduler, the link
    /// drops with it, and it ticks again from the next frame once the cap lifts. A fair thermal state
    /// pauses nothing.
    @Test(arguments: PowerState.cappedExamples)
    func ambientPausesUnderThePowerCap(_ capped: PowerState) {
        let links = PowerRateLinks()
        let displays = DisplayClock(makeLink: links.make, displayOf: { _ in 1 }, clock: ManualClock())
        let scheduler = FrameScheduler(name: "w", host: .screen, displays: displays, budget: nil)
        var ticks = 0
        let spinner = FrameClient(owner: "spinner", rate: .ambient, on: scheduler) { _ in ticks += 1; return true }
        spinner.activate()
        displays.displayDidFire(1, timestamp: 1, refreshInterval: 1.0 / 120)
        #expect(ticks == 1)
        #expect(displays.powerSubscribers == ["spinner"])

        displays.power = PowerState(thermal: .fair)
        #expect(!spinner.isPowerPaused, "a fair thermal state caps nothing")
        #expect(scheduler.activeClients == ["spinner"])

        displays.power = capped
        #expect(spinner.isActive)
        #expect(spinner.isPowerPaused && spinner.isParked)
        #expect(scheduler.activeClients.isEmpty)
        #expect(displays.liveLinks == 0, "the paused spinner was the only client: no link, no frame wakeups")
        displays.displayDidFire(1, timestamp: 2, refreshInterval: 1.0 / 120)
        #expect(ticks == 1, "a paused ambient client gets no frame")

        displays.power = .nominal
        #expect(!spinner.isPowerPaused && !spinner.isParked)
        #expect(scheduler.activeClients == ["spinner"])
        #expect(displays.liveLinks == 1)
        displays.displayDidFire(1, timestamp: 3, refreshInterval: 1.0 / 120)
        #expect(ticks == 2, "it ticks again once the cap lifts")
        spinner.deactivate()
        #expect(displays.liveLinks == 0)
    }

    /// An ambient client that activates under the cap starts paused and makes no link; the cap
    /// lifting starts it.
    @Test func ambientActivatedUnderTheCapMakesNoLink() {
        let links = PowerRateLinks()
        let displays = DisplayClock(makeLink: links.make, displayOf: { _ in 1 }, clock: ManualClock(),
                                    power: PowerState(lowPowerMode: true))
        let scheduler = FrameScheduler(name: "w", host: .screen, displays: displays, budget: nil)
        let breath = FrameClient(owner: "breath", rate: .slow(4), on: scheduler) { _ in true }
        breath.activate()
        #expect(breath.isPowerPaused)
        #expect(links.made.isEmpty)

        displays.power = .nominal
        #expect(links.made.count == 1)
        #expect(scheduler.activeClients == ["breath"])
        breath.deactivate()
        #expect(!breath.isPowerPaused, "an idle client is not paused")
        #expect(displays.liveLinks == 0)
    }

    /// `.ui` caps at 60 under the cap, at once, even while links do not follow client rates (where a
    /// ui client otherwise runs the motion range); the cap lifting brings the motion range back at once.
    @Test(arguments: [false, true])
    func uiCapsAt60UnderThePowerCap(followsClientRates: Bool) throws {
        let links = PowerRateLinks()
        let displays = DisplayClock(makeLink: links.make, displayOf: { _ in 1 }, clock: ManualClock(),
                                    followsClientRates: followsClientRates)
        let scheduler = FrameScheduler(name: "w", host: .screen, displays: displays, budget: nil)
        var ticks = 0
        let content = FrameClient(owner: "content", rate: .ui, on: scheduler) { _ in ticks += 1; return true }
        content.activate()
        let link = try #require(links.made.first)
        #expect(displays.frameRate(on: 1) == (followsClientRates ? .ui : .motion))
        #expect(displays.powerSubscribers.isEmpty, "only an ambient client follows the power state")

        displays.power = PowerState(lowPowerMode: true)
        #expect(!content.isPowerPaused, "a ui client never pauses")
        #expect(scheduler.linkRate == .ui)
        #expect(displays.frameRate(on: 1) == .ui)
        let capped = try #require(link.requested.last)
        #expect(capped.minimum == 60 && capped.maximum == 60)
        displays.firePowerFrames(1, frames: DisplayClock.framesBeforeLowering)
        #expect(ticks == DisplayClock.framesBeforeLowering, "a ui client keeps ticking under the cap")
        #expect(displays.frameRate(on: 1) == .ui)

        displays.power = .nominal
        #expect(displays.frameRate(on: 1) == (followsClientRates ? .ui : .motion))
        #expect(link.requested.last?.maximum == (followsClientRates ? 60 : 120))
        content.deactivate()
        #expect(displays.liveLinks == 0)
    }

    /// `.motion` is unchanged under the cap: it keeps the 80 to 120 Hz range and every frame while an
    /// ambient client beside it pauses.
    @Test(arguments: PowerState.cappedExamples)
    func motionIsUnchangedUnderThePowerCap(_ capped: PowerState) throws {
        let links = PowerRateLinks()
        let displays = DisplayClock(makeLink: links.make, displayOf: { _ in 1 }, clock: ManualClock())
        let scheduler = FrameScheduler(name: "w", host: .screen, displays: displays, budget: nil)
        var springTicks = 0, spinnerTicks = 0
        let spring = FrameClient(owner: "spring", on: scheduler) { _ in springTicks += 1; return true }
        let spinner = FrameClient(owner: "spinner", rate: .ambient, on: scheduler) { _ in spinnerTicks += 1; return true }
        spring.activate()
        spinner.activate()

        displays.power = capped
        #expect(!spring.isPowerPaused)
        #expect(spinner.isPowerPaused)
        #expect(scheduler.activeClients == ["spring"])
        #expect(scheduler.linkRate == .motion)
        displays.firePowerFrames(1, frames: DisplayClock.framesBeforeLowering)
        #expect(springTicks == DisplayClock.framesBeforeLowering)
        #expect(spinnerTicks == 0)
        #expect(displays.frameRate(on: 1) == .motion)
        let link = try #require(links.made.first)
        #expect(links.made.count == 1)
        #expect(link.requested.allSatisfy { $0.minimum == 80 && $0.maximum == 120 })

        displays.power = .nominal
        #expect(scheduler.activeClients == ["spinner", "spring"])
        spring.deactivate()
        spinner.deactivate()
        #expect(displays.liveLinks == 0)
    }

    /// A released ambient client leaves no power subscription behind.
    @Test func aReleasedAmbientClientDropsItsPowerSubscription() {
        let displays = DisplayClock(makeLink: PowerRateLinks().make, displayOf: { _ in 1 }, clock: ManualClock())
        let scheduler = FrameScheduler(name: "w", host: .screen, displays: displays, budget: nil)
        var spinner: FrameClient? = FrameClient(owner: "spinner", rate: .ambient, on: scheduler) { _ in true }
        spinner?.activate()
        #expect(displays.powerSubscribers == ["spinner"])
        spinner?.deactivate()
        spinner = nil
        #expect(displays.powerSubscribers.isEmpty)
        displays.power = PowerState(lowPowerMode: true)
        #expect(displays.liveLinks == 0)
    }
}

extension PowerState {
    /// The states that cap frames: Low Power Mode, a serious or critical thermal state, and Low Power
    /// Mode on a fair one.
    fileprivate static let cappedExamples = [PowerState(lowPowerMode: true), PowerState(thermal: .serious),
                                             PowerState(thermal: .critical), PowerState(lowPowerMode: true, thermal: .fair)]
}

extension DisplayClock {
    /// `frames` link frames of `display` at 120 Hz, the first `1 / 120` s after `start`.
    fileprivate func firePowerFrames(_ display: CGDirectDisplayID, frames: Int, from start: CFTimeInterval = 0) {
        for frame in 0..<max(frames, 0) {
            displayDidFire(display, timestamp: start + Double(frame + 1) / 120, refreshInterval: 1.0 / 120)
        }
    }
}

/// A link that records the rates it was asked for.
@MainActor
private final class PowerRateLink: FrameLink {
    var isPaused = false
    private(set) var requested: [CAFrameRateRange] = []
    func invalidate() {}
    func requestFrameRate(_ range: CAFrameRateRange) { requested.append(range) }
}

@MainActor
private final class PowerRateLinks {
    private(set) var made: [PowerRateLink] = []
    var make: DisplayClock.LinkFactory {
        { [self] _, _ in
            let link = PowerRateLink()
            made.append(link)
            return link
        }
    }
}
