import AppKit
import Testing
@testable import MessagesLabHome

/// The scroller's three one-shot deadlines (fade-in, widen, hide) come from the host's timer
/// (`ChatWakeScheduler.makeDeadline`, CmuxNext: a visible-class MainDeadline), the fade-in exact and
/// the others flexible, and none repeats.
@MainActor @Suite(.serialized) struct NativeScrollDeadlineTests {
    /// A deadline the test fires by hand; it records what it was asked for.
    @MainActor final class HandDeadline: ViewDeadline {
        let owner: String
        let exact: Bool
        private(set) var action: (@MainActor @Sendable () -> Void)?
        private(set) var delay: Double?
        private(set) var schedules = 0

        init(owner: String, exact: Bool) {
            self.owner = owner
            self.exact = exact
        }

        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {
            schedules += 1
            delay = seconds
            self.action = action
        }

        func cancel() { action = nil }

        var isPending: Bool { action != nil }

        /// Runs the pending action once, as the host's timer does at the deadline.
        func fire() {
            let pending = action
            action = nil
            pending?()
        }
    }

    final class HandWake: ChatWakeScheduler {
        private(set) var deadlines: [String: HandDeadline] = [:]
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
        @MainActor func makeDeadline(owner: String, exact: Bool) -> any ViewDeadline {
            let deadline = HandDeadline(owner: owner, exact: exact)
            deadlines[owner] = deadline
            return deadline
        }
    }

    private func scroller(_ wake: HandWake) throws -> (ChatController, SequenceScroller) {
        _ = NSApplication.shared
        let controller = ChatController(host: HostView(frame: NSRect(x: 0, y: 0, width: 600, height: 700)), wake: wake)
        let scroller = try #require(controller.host.scrollView.verticalScroller as? SequenceScroller)
        return (controller, scroller)
    }

    @Test func theScrollerTakesItsThreeDeadlinesFromTheHost() throws {
        let wake = HandWake()
        let (controller, _) = try scroller(wake)
        #expect(Set(wake.deadlines.keys) == ["Home.scroller.hide", "Home.scroller.show", "Home.scroller.expand"])
        _ = controller
    }

    /// The fade-in is exact, the widening and the hide flexible; each runs once and sets the
    /// scroller's state. Legacy scrollers never fade.
    @Test func revealWidenAndHideRunOnTheHostsDeadlines() throws {
        let wake = HandWake()
        let (controller, scroller) = try scroller(wake)
        defer { _ = controller }
        // The system's "Show scroll bars: Always" keeps the scroller shown, with no deadline at all.
        guard !scroller.legacy else { return }
        let show = try #require(wake.deadlines["Home.scroller.show"])
        let expand = try #require(wake.deadlines["Home.scroller.expand"])
        let hide = try #require(wake.deadlines["Home.scroller.hide"])

        scroller.reveal()
        #expect(scroller.shown)
        #expect(show.exact && !expand.exact && !hide.exact)
        #expect(show.isPending && show.delay == SequenceScroller.showDelay)
        #expect(hide.isPending)
        #expect(hide.delay == SequenceScroller.holdTime + SequenceScroller.fadeTime)
        show.fire()

        let enter = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                                        windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        scroller.mouseEntered(with: enter)
        #expect(!hide.isPending, "the pointer in the strip keeps the scroller")
        #expect(expand.isPending && expand.delay == SequenceScroller.expandDelay)
        #expect(!scroller.expanded)
        expand.fire()
        #expect(scroller.expanded)

        let exit = try #require(NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
                                                       windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        scroller.mouseExited(with: exit)
        #expect(hide.isPending)
        hide.fire()
        #expect(!scroller.shown && !scroller.expanded)
        #expect(!show.isPending && !expand.isPending && !hide.isPending, "nothing re-arms itself")
        #expect(show.schedules == 1 && expand.schedules == 1)
    }
}
