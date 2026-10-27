@testable import CmuxNextHibernation
import Testing

/// p03-rendering-096's detach arm (feature `hiddenWorkspaceDetachAfterGrace`): a workspace hidden past the
/// grace leaves its window, never within it, the oldest first, one per deadline turn; a workspace shown,
/// torn down or shown beside the shown one is forgotten.
@MainActor @Suite struct HiddenWorkspaceDetachTests {
    final class FakeDeadline: HiddenWorkspaceDetachDeadline {
        private(set) var delay: Duration?
        private var action: (@MainActor () -> Void)?
        func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) {
            self.delay = delay
            self.action = action
        }

        func cancel() {
            delay = nil
            action = nil
        }

        func fire() {
            let pending = action
            delay = nil
            action = nil
            pending?()
        }
    }

    /// A window's main pane: what it holds hidden, and what left it.
    final class Host: HiddenWorkspaceDetachHost {
        var hidden: [ObjectIdentifier] = []
        private(set) var detached: [ObjectIdentifier] = []
        func holdsHidden(_ workspace: AnyObject) -> Bool { hidden.contains(ObjectIdentifier(workspace)) }
        func detach(_ workspace: AnyObject) {
            hidden.removeAll { $0 == ObjectIdentifier(workspace) }
            detached.append(ObjectIdentifier(workspace))
        }
    }

    final class Workspace {}

    final class Clock {
        var now = ContinuousClock.now
    }

    let deadline = FakeDeadline(), clock = Clock(), host = Host()

    func makeDetach() -> HiddenWorkspaceDetach {
        let clock = self.clock
        let detach = HiddenWorkspaceDetach(grace: .seconds(30), deadline: deadline, now: { clock.now })
        detach.host = host
        return detach
    }

    func hide(_ workspace: Workspace, in detach: HiddenWorkspaceDetach) {
        host.hidden.append(ObjectIdentifier(workspace))
        detach.didHide(workspace)
    }

    @Test func aWorkspaceShownWithinTheGraceNeverLeaves() {
        let detach = makeDetach(), a = Workspace()
        hide(a, in: detach)
        #expect(deadline.delay == .seconds(30), "the grace is armed in the hide's turn")
        clock.now += .seconds(29)
        host.hidden = []
        detach.willShow(a)
        #expect(deadline.delay == nil && detach.pendingCount == 0, "shown within the grace: nothing waits")
        #expect(host.detached.isEmpty && detach.detachedCount == 0)
    }

    @Test func workspacesPastTheGraceLeaveOldestFirstOnePerTurn() {
        let detach = makeDetach(), a = Workspace(), b = Workspace(), c = Workspace()
        hide(a, in: detach)
        clock.now += .seconds(5)
        hide(b, in: detach)
        clock.now += .seconds(10)
        hide(c, in: detach)
        #expect(deadline.delay == .seconds(15), "one deadline, aimed at the oldest's grace end")

        clock.now += .seconds(25) // a hid 40 s ago, b 35 s, c 25 s
        deadline.fire()
        #expect(host.detached == [ObjectIdentifier(a)], "the oldest leaves first, alone")
        #expect(deadline.delay == .zero, "b's grace ended too: it leaves on the next turn")
        deadline.fire()
        #expect(host.detached == [ObjectIdentifier(a), ObjectIdentifier(b)])
        #expect(deadline.delay == .seconds(5), "c leaves at its own grace end, not before")
        deadline.fire()
        #expect(host.detached.count == 2, "a deadline that fires early takes nothing")
        clock.now += .seconds(5)
        deadline.fire()
        #expect(host.detached.count == 3 && detach.detachedCount == 3)
        #expect(deadline.delay == nil, "nothing waits: no deadline stays armed")
        _ = (a, b, c)
    }

    @Test func aWorkspaceTheHostNoLongerHoldsHiddenIsForgotten() {
        let detach = makeDetach(), a = Workspace(), b = Workspace()
        hide(a, in: detach)
        hide(b, in: detach)
        // a was torn down; b shows beside the shown workspace (not through a show).
        host.hidden = []
        clock.now += .seconds(31)
        deadline.fire()
        #expect(host.detached.isEmpty && detach.pendingCount == 0)
        #expect(deadline.delay == nil)
        _ = (a, b)
    }

    @Test func aWorkspaceHiddenAgainStartsItsGraceOver() {
        let detach = makeDetach(), a = Workspace()
        hide(a, in: detach)
        clock.now += .seconds(20)
        detach.didHide(a)
        #expect(detach.pendingCount == 1)
        #expect(deadline.delay == .seconds(30))
        clock.now += .seconds(20)
        deadline.fire()
        #expect(host.detached.isEmpty, "the grace counts from the last hide")
        _ = a
    }
}
