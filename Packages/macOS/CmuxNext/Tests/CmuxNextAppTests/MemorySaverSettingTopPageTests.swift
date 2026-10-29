import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextMemory
import CmuxNextPages
import Testing

/// Hidden top pages follow `memory.saver` through the memory coordinator: the mode
/// scales a page's timeout (aggressive: half; off: no timed release), a change of mode plans again
/// right after its turn, and at critical pressure a hidden page goes whatever the mode, never one
/// the person just left.
@MainActor @Suite struct MemorySaverSettingTopPageTests {
    private static let history = TopPageRoute.page(.history)
    private static let timeout = Duration.seconds(600)

    @Test func aggressiveReleasesAHiddenPageAtHalfItsTimeout() throws {
        let rig = Rig()
        rig.coordinator.mode = .aggressive
        #expect(rig.host.saverMode == .aggressive, "the coordinator did not hand the mode to the top page host")
        try rig.hide()
        rig.fire()
        #expect(rig.deadline.delay == Self.timeout / 2, "aggressive waits half the page's own timeout")

        rig.clock.advance(Self.timeout / 2 - .seconds(1))
        rig.fire()
        #expect(rig.host.views[Self.history] != nil, "a page hidden less than half its timeout went")
        rig.clock.advance(.seconds(2))
        rig.fire()
        #expect(rig.host.views[Self.history] == nil, "aggressive kept the page past half its timeout")
    }

    @Test func offReleasesNothingByTimeout() throws {
        let rig = Rig()
        rig.coordinator.mode = .off
        try rig.hide()
        rig.fire()
        #expect(!rig.deadline.armed, "with Memory Saver off a hidden page needs no deadline")
        rig.clock.advance(.seconds(3600))
        rig.host.plan()
        #expect(rig.host.views[Self.history] != nil, "Memory Saver off released a page by its timeout")
    }

    @Test func aModeChangePlansAgainRightAfterItsTurn() throws {
        let rig = Rig()
        try rig.hide()
        rig.fire()
        #expect(rig.deadline.delay == Self.timeout, "medium waits the page's own timeout")

        rig.clock.advance(.seconds(400))
        rig.coordinator.mode = .aggressive
        #expect(rig.deadline.delay == .zero, "a mode change did not plan again right after its turn")
        #expect(rig.host.views[Self.history] != nil, "the mode change released a page in its own turn")
        rig.fire()
        #expect(rig.host.views[Self.history] == nil, "a page hidden past the new mode's timeout stayed")
    }

    @Test func criticalPressureReleasesAHiddenPageWithMemorySaverOff() throws {
        let rig = Rig()
        rig.coordinator.mode = .off
        try rig.hide()
        rig.fire()
        rig.clock.advance(.seconds(10))

        rig.kernel.send(.critical)
        #expect(rig.host.pressure == .critical)
        #expect(rig.deadline.delay == .zero, "critical pressure did not plan again right after its turn")
        rig.fire()
        #expect(rig.host.views[Self.history] != nil, "critical pressure released a page the person just left")
        #expect(rig.deadline.delay == TopPageHost.budgetMinimumHidden - .seconds(10),
                "the deadline is when the page is no longer just left")

        rig.clock.advance(TopPageHost.budgetMinimumHidden)
        rig.slices.runAll()
        #expect(rig.host.views[Self.history] == nil, "the critical limit's release slice freed nothing with Memory Saver off")
        #expect(rig.host.releasedCount == 1)
    }

    @Test func offTheFeatureTheHostDoesNotRegister() {
        let rig = Rig(discards: false)
        let report = rig.coordinator.report(budget: SubsystemBudget.forThisMac(gpuResidentAvailable: false))
        #expect(report.consumers.isEmpty, "a host that discards nothing registered as a lossy consumer")
    }
}

@MainActor
private final class Rig {
    let kernel: ManualMemoryPressureSource
    let slices: BrowserHibernationPressureTests.HeldSlices
    let coordinator: MemoryCoordinator
    let clock: FakeClock
    let deadline: FakeDeadline
    let host: TopPageHost
    private let pressure: MemoryPressureEvents

    init(discards: Bool = true) {
        let kernel = ManualMemoryPressureSource(), slices = BrowserHibernationPressureTests.HeldSlices()
        let pressure = MemoryPressureEvents(source: kernel)
        let coordinator = MemoryCoordinator(pressure: pressure, slicer: slices)
        let clock = FakeClock(), deadline = FakeDeadline(), owner = FakeOwner()
        let hosts = HostList()
        let host = TopPageHost(make: { _, _ in (NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120)), "key-history") },
                               closed: { _, _ in }, discardable: { _, _ in owner }, title: { $0.rawValue },
                               discards: discards, hiddenLimit: 8, hosts: { hosts.hosts }, deadline: deadline, memory: coordinator)
        host.now = { clock.now }
        hosts.hosts = [host]
        self.kernel = kernel
        self.slices = slices
        self.pressure = pressure
        self.coordinator = coordinator
        self.clock = clock
        self.deadline = deadline
        self.host = host
    }

    /// Makes History's page and hides it.
    func hide() throws {
        _ = try #require(host.view(for: .page(.history), in: nil))
        host.contentDidChange(shown: nil)
    }

    /// Runs the host's pending deadline, as its timer would.
    func fire() { deadline.fire() }
}

/// Every window's host (one here), for the hidden-page budget.
@MainActor
private final class HostList {
    var hosts: [TopPageHost] = []
}

private final class FakeClock {
    private(set) var now = ContinuousClock.now
    func advance(_ duration: Duration) { now = now.advanced(by: duration) }
}

@MainActor
private final class FakeDeadline: PageDiscardDeadline {
    private(set) var delay: Duration?
    private var action: (@MainActor () -> Void)?
    var armed: Bool { action != nil }

    func arm(after delay: Duration, _ action: @escaping @MainActor () -> Void) {
        self.delay = delay
        self.action = action
    }

    func disarm() {
        delay = nil
        action = nil
    }

    func fire() {
        guard let action else { return }
        self.action = nil
        delay = nil
        action()
    }
}

/// An owner with the standard policy (10 minutes) that takes every other default.
@MainActor
private final class FakeOwner: PageDiscardable {}
