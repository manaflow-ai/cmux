import AppKit
import CmuxNextWakeupsTestSupport
@testable import CmuxNextWakeups
import QuartzCore
import Testing

/// The opt-in ambient class under Energy Saver: every existing client is
/// ``FrameRate/motion``; an ambient client alone asks the link for at most
/// ``EnergyPolicy/ambientMaxFPS`` under the saver and the motion range outside it, a motion client
/// beside it keeps the motion range, and ambient clients wait while the displays sleep. Chrome's
/// battery saver throttles frame sinks to 30 Hz the same way
/// (components/viz/service/frame_sinks/frame_sink_manager_impl.cc).
@MainActor @Suite(.timeLimit(.minutes(1))) struct FrameSchedulerRateClassTests {
    private static let saver = EnergyPolicy(saverReason: .setting)

    /// The key-to-frame clients and probes (TerminalFrameHold, ResizeCoordinator, DebugFrameProbe,
    /// MotionFrameTrace, SwitchFrameTimer, DebugMainCPUProbe: `isAnimation: false`, no rate), a
    /// FrameBatchQueue, budgeted batches and the input stage are motion, and keep the motion range
    /// under the saver.
    @Test func everyExistingClientIsMotion() throws {
        let links = RateClassLinks()
        let displays = DisplayClock(makeLink: links.make, displayOf: { _ in 1 }, clock: ManualClock())
        let scheduler = FrameScheduler(name: "w", host: .screen, displays: displays, budget: nil)
        let energy = EnergyPolicySource(Self.saver)
        scheduler.follow(energy)

        let hold = FrameClient(owner: "TerminalFrameHold", isAnimation: false, scheduler: { scheduler }) { _ in true }
        let probe = FrameClient(owner: "debug.frames", isAnimation: false, on: scheduler) { _ in true }
        let input = FrameClient(inputStageOf: scheduler, owner: "input") { _ in true }
        let work = MainWorkScheduler.testing { _ in RateClassLink() }
        let batch = FrameClient(owner: "Control.frames", budgeted: .automation, on: work) { _, _ in true }
        for client in [hold, probe, input, batch] {
            #expect(client.rate == .motion, "\(client.owner)")
            #expect(!client.rate.isAmbient)
        }

        let queue = FrameBatchQueue(owner: "FrameBatchQueue", scheduler: scheduler)
        queue.enqueue {}
        #expect(scheduler.activeClients == ["FrameBatchQueue"])
        #expect(scheduler.frameRate == .motion, "a FrameBatchQueue's client is motion")
        #expect(scheduler.linkRate == .motion)
        hold.activate()
        #expect(scheduler.frameRate == .motion)
        #expect(scheduler.linkRate == .motion)
        #expect(displays.frameRate(on: 1) == .motion)
        displays.fireRateClass(1, frames: DisplayClock.framesBeforeLowering)
        #expect(displays.frameRate(on: 1) == .motion, "the saver never lowers motion clients")
        #expect(try #require(links.made.first).requested.allSatisfy { $0.minimum == 80 && $0.maximum == 120 })
        hold.deactivate()
    }

    /// An ambient client alone: the motion range outside the saver; under the saver the link drops to
    /// at most 30 Hz once the lower rate held ``DisplayClock/framesBeforeLowering`` frames, and the
    /// saver going off brings the motion range back at once.
    @Test func ambientAloneIsAtMost30UnderTheSaverOnly() throws {
        let links = RateClassLinks()
        let displays = DisplayClock(makeLink: links.make, displayOf: { _ in 1 }, clock: ManualClock())
        let scheduler = FrameScheduler(name: "w", host: .screen, displays: displays, budget: nil)
        let energy = EnergyPolicySource()
        scheduler.follow(energy)
        let spinner = FrameClient(owner: "spinner", rate: .ambient, on: scheduler) { _ in true }

        spinner.activate()
        let link = try #require(links.made.first)
        #expect(displays.frameRate(on: 1) == .motion, "ambient outside the saver runs the motion range")
        #expect(link.requested.last?.maximum == 120)

        energy.update(Self.saver)
        #expect(scheduler.ambientCap == EnergyPolicy.saverFrameRate)
        #expect(scheduler.linkRate == .ambient)
        #expect(displays.frameRate(on: 1) == .motion, "lowering waits for frames")
        displays.fireRateClass(1, frames: DisplayClock.framesBeforeLowering - 1)
        #expect(displays.frameRate(on: 1) == .motion)
        displays.fireRateClass(1, frames: 1, from: 1)
        #expect(displays.frameRate(on: 1) == .ambient)
        let capped = try #require(link.requested.last)
        // No preferred rate (nil) leaves the system to pick within the maximum.
        #expect(capped.maximum <= 30 && (capped.preferred ?? capped.maximum) <= 30)

        energy.update(.normal)
        #expect(scheduler.ambientCap == nil)
        #expect(displays.frameRate(on: 1) == .motion, "the saver off raises the link at once")
        #expect(link.requested.last?.maximum == 120)
        spinner.deactivate()
        #expect(displays.liveLinks == 0)
    }

    /// Under the saver an ambient client that starts alone gets the capped rate on its first request.
    @Test func ambientStartingUnderTheSaverAsksForTheCapAtOnce() throws {
        let links = RateClassLinks()
        let displays = DisplayClock(makeLink: links.make, displayOf: { _ in 1 }, clock: ManualClock())
        let scheduler = FrameScheduler(name: "w", host: .screen, displays: displays, budget: nil)
        scheduler.follow(EnergyPolicySource(Self.saver))
        let breath = FrameClient(owner: "breath", rate: .ambient, on: scheduler) { _ in true }
        breath.activate()
        #expect(displays.frameRate(on: 1) == .ambient)
        #expect(try #require(links.made.first).requested.map(\.maximum) == [30])
        breath.deactivate()
    }

    /// Motion beside ambient under the saver: 80 to 120 Hz, at once; the motion client leaving lowers
    /// the link to the cap after ``DisplayClock/framesBeforeLowering`` frames.
    @Test func motionBesideAmbientKeepsTheMotionRange() throws {
        let links = RateClassLinks()
        let displays = DisplayClock(makeLink: links.make, displayOf: { _ in 1 }, clock: ManualClock())
        let scheduler = FrameScheduler(name: "w", host: .screen, displays: displays, budget: nil)
        scheduler.follow(EnergyPolicySource(Self.saver))
        let spinner = FrameClient(owner: "spinner", rate: .ambient, on: scheduler) { _ in true }
        let spring = FrameClient(owner: "spring", on: scheduler) { _ in true }

        spinner.activate()
        spring.activate()
        #expect(displays.frameRate(on: 1) == .motion)
        let motion = try #require(links.made.first?.requested.last)
        #expect(motion.minimum == 80 && motion.maximum == 120)

        spring.deactivate()
        displays.fireRateClass(1, frames: DisplayClock.framesBeforeLowering)
        #expect(displays.frameRate(on: 1) == .ambient)
        spinner.deactivate()
    }

    /// With the client rates followed (feature `frameRateClasses`) the cap applies to a stepping
    /// rate too, and never touches a ui or motion rate.
    @Test func theCapOnlyLowersAmbientRates() {
        #expect(FrameRate.ambient.onLink(followingClasses: false, ambientCap: nil) == .motion)
        #expect(FrameRate.ambient.onLink(followingClasses: true, ambientCap: nil) == .ambient)
        #expect(FrameRate.ambient.onLink(followingClasses: false, ambientCap: 30) == .ambient)
        #expect(FrameRate.ambient.onLink(followingClasses: true, ambientCap: 20) == .slow(20))
        #expect(FrameRate.slow(5).onLink(followingClasses: false, ambientCap: 30) == .slow(5))
        #expect(FrameRate.ui.onLink(followingClasses: false, ambientCap: 30) == .motion)
        #expect(FrameRate.ui.onLink(followingClasses: true, ambientCap: 30) == .ui)
        #expect(FrameRate.motion.onLink(followingClasses: true, ambientCap: 30) == .motion)
        #expect(FrameRate.slow(4).isAmbient && FrameRate.ambient.isAmbient)
        #expect(!FrameRate.ui.isAmbient && !FrameRate.motion.isAmbient)
    }

    /// The displays going to sleep stop the ambient clients (an ambient-only display drops its link)
    /// and leave motion work ticking; waking them brings the ambient clients back.
    @Test func screensAsleepStopsAmbientClients() throws {
        let links = RateClassLinks()
        let displays = DisplayClock(makeLink: links.make, displayOf: { _ in 1 }, clock: ManualClock())
        let scheduler = FrameScheduler(name: "w", host: .screen, displays: displays, budget: nil)
        let energy = EnergyPolicySource()
        scheduler.follow(energy)
        var spinnerTicks = 0, mirrorTicks = 0
        let spinner = FrameClient(owner: "spinner", rate: .ambient, on: scheduler) { _ in
            spinnerTicks += 1
            return true
        }
        let mirror = FrameClient(owner: "mirror", isAnimation: false, on: scheduler) { _ in
            mirrorTicks += 1
            return true
        }
        spinner.activate()
        mirror.activate()

        energy.update(EnergyPolicy(screensAsleep: true))
        #expect(scheduler.asleepClients == ["spinner"])
        #expect(scheduler.activeClients == ["mirror"])
        #expect(spinner.isActive, "a waiting client stays active for its owner")
        displays.fireRateClass(1, frames: 3)
        #expect(spinnerTicks == 0 && mirrorTicks == 3)

        mirror.deactivate()
        #expect(displays.liveLinks == 0, "only a waiting ambient client left: no link")
        let late = FrameClient(owner: "late", rate: .slow(4), on: scheduler) { _ in true }
        late.activate()
        #expect(scheduler.asleepClients == ["late", "spinner"])
        #expect(displays.liveLinks == 0)
        late.deactivate()
        #expect(scheduler.asleepClients == ["spinner"])

        energy.update(.normal)
        #expect(scheduler.asleepClients.isEmpty)
        #expect(scheduler.activeClients == ["spinner"])
        #expect(displays.liveLinks == 1)
        displays.fireRateClass(1, frames: 2, from: 1)
        #expect(spinnerTicks == 2)
        spinner.deactivate()
        #expect(displays.liveLinks == 0)
    }

    /// A client that went idle while the displays slept does not come back when they wake, and an
    /// invalidated scheduler lets go of its waiting clients.
    @Test func idleOrInvalidatedWaitingClientsStayGone() {
        let displays = DisplayClock(makeLink: RateClassLinks().make, displayOf: { _ in 1 }, clock: ManualClock())
        let scheduler = FrameScheduler(name: "w", host: .screen, displays: displays, budget: nil)
        let energy = EnergyPolicySource(EnergyPolicy(screensAsleep: true))
        scheduler.follow(energy)
        let spinner = FrameClient(owner: "spinner", rate: .ambient, on: scheduler) { _ in true }
        let pulse = FrameClient(owner: "pulse", rate: .ambient, on: scheduler) { _ in true }
        spinner.activate()
        pulse.activate()
        spinner.deactivate()
        #expect(scheduler.asleepClients == ["pulse"])

        scheduler.invalidate()
        #expect(scheduler.asleepClients.isEmpty)
        #expect(!pulse.isActive)
        energy.update(.normal)
        #expect(scheduler.activeClients.isEmpty)
        #expect(displays.liveLinks == 0)
    }

    /// The ``MainWorkScheduler``'s frame scheduler follows the policy that scheduler owns.
    @Test func theBudgetedSchedulerFollowsItsOwnersPolicy() {
        let work = MainWorkScheduler.testing { _ in RateClassLink() }
        #expect(work.frames.energy === work.energy)
        #expect(work.frames.ambientCap == nil)
        work.energy.update(Self.saver)
        #expect(work.frames.ambientCap == EnergyPolicy.saverFrameRate)
        work.energy.update(.normal)
        #expect(work.frames.ambientCap == nil)
    }

    /// ``FrameScheduler/install(displays:energy:)`` puts ``FrameScheduler/app`` under the app's policy,
    /// and every window scheduler made after it follows the same policy, so view-hosted ambient
    /// clients (`FrameClient(view:)`, ``FrameScheduler/forView(_:)``) are capped under the saver too.
    /// It installs the clock `app` already has, so `app` is not replaced under parallel tests.
    @Test func theAppAndWindowSchedulersFollowTheInstalledPolicy() {
        let energy = EnergyPolicySource()
        defer { energy.update(.normal) }
        FrameScheduler.install(displays: FrameScheduler.appDisplays, energy: energy)
        #expect(FrameScheduler.app.energy === energy)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scheduler = FrameScheduler.forWindow(window)
        #expect(scheduler.energy === energy)
        #expect(scheduler.ambientCap == nil)

        energy.update(Self.saver)
        #expect(FrameScheduler.app.ambientCap == EnergyPolicy.saverFrameRate)
        #expect(scheduler.ambientCap == EnergyPolicy.saverFrameRate)
        energy.update(.normal)
        #expect(scheduler.ambientCap == nil)
    }
}

extension DisplayClock {
    /// `frames` link frames of `display` at 120 Hz, the first `1 / 120` s after `start`.
    fileprivate func fireRateClass(_ display: CGDirectDisplayID, frames: Int, from start: CFTimeInterval = 0) {
        for frame in 0..<max(frames, 0) {
            displayDidFire(display, timestamp: start + Double(frame + 1) / 120, refreshInterval: 1.0 / 120)
        }
    }
}

/// A link that records the rates it was asked for.
@MainActor
private final class RateClassLink: FrameLink {
    var isPaused = false
    private(set) var requested: [CAFrameRateRange] = []
    func invalidate() {}
    func requestFrameRate(_ range: CAFrameRateRange) { requested.append(range) }
}

@MainActor
private final class RateClassLinks {
    private(set) var made: [RateClassLink] = []
    var make: DisplayClock.LinkFactory {
        { [self] _, _ in
            let link = RateClassLink()
            made.append(link)
            return link
        }
    }
}
