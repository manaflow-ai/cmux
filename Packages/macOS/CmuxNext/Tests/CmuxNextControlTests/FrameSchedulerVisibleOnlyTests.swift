import CmuxNextWakeups
import Foundation
import QuartzCore
import Testing

/// A ``FrameClient`` made with a `visibleOnly` node draws only for someone: while
/// the node is hidden or occluded and no capture vote holds it, the client stays active but is never
/// ticked, and its window's link drops when it was the only client. Chrome stops a hidden widget's
/// BeginFrames the same way (`cc::Scheduler`'s `visible` input, cc/scheduler/scheduler_state_machine.cc).
@MainActor @Suite(.timeLimit(.minutes(1))) struct FrameSchedulerVisibleOnlyTests {
    @Test func aHiddenVisibleOnlyClientIsNeverTicked() {
        let links = VisibleOnlyLinks()
        let scheduler = FrameScheduler.testing(mediaTime: { 500 }) { _ in links.make() }
        let window = VisibilityNode(root: "window", own: .hidden)
        var ticks = 0
        let client = FrameClient(owner: "glass", visibleOnly: window, on: scheduler) { _ in ticks += 1; return true }
        client.activate()
        #expect(client.isActive && client.isParked, "an unseen client is not parked")
        #expect(scheduler.activeClients.isEmpty, "an unseen client joins its scheduler")
        #expect(!scheduler.hasLink && links.made == 0, "an unseen client makes a link")
        for frame in 1...5 { scheduler.frameDidFire(timestamp: Double(frame), refreshInterval: 1.0 / 60) }
        #expect(ticks == 0, "a hidden visibleOnly client ticked \(ticks) times")
        window.set(.occluded)
        scheduler.frameDidFire(timestamp: 6, refreshInterval: 1.0 / 60)
        #expect(ticks == 0, "an occluded visibleOnly client ticked")
        client.deactivate()
    }

    /// The acceptance: hiding the window of the only client drops its link; showing it again makes one
    /// and the client ticks from the next frame.
    @Test func theLinkDropsWhenTheOnlyClientsWindowHides() {
        let links = VisibleOnlyLinks()
        let scheduler = FrameScheduler.testing(mediaTime: { 500 }) { _ in links.make() }
        let window = VisibilityNode(root: "window", own: .visible)
        var ticks = 0
        let client = FrameClient(owner: "glass", visibleOnly: window, on: scheduler) { _ in ticks += 1; return true }
        client.activate()
        #expect(scheduler.hasLink && links.made == 1)
        scheduler.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(ticks == 1)
        window.set(.hidden)
        #expect(!scheduler.hasLink, "the hidden window's link stays")
        #expect(links.invalidated == 1, "the link was not dropped")
        #expect(client.isActive && client.isParked)
        scheduler.frameDidFire(timestamp: 2, refreshInterval: 1.0 / 60)
        #expect(ticks == 1, "a hidden visibleOnly client ticked")
        window.set(.visible)
        #expect(scheduler.hasLink && links.made == 2, "showing the window does not bring the link back")
        #expect(!client.isParked)
        scheduler.frameDidFire(timestamp: 3, refreshInterval: 1.0 / 60)
        #expect(ticks == 2, "the client does not tick again once its window shows")
        client.deactivate()
        #expect(!scheduler.hasLink)
    }

    /// Another client keeps the link: only the hidden one stops ticking.
    @Test func aHiddenClientLeavesTheLinkToTheOthers() {
        let links = VisibleOnlyLinks()
        let scheduler = FrameScheduler.testing(mediaTime: { 500 }) { _ in links.make() }
        let window = VisibilityNode(root: "window", own: .visible)
        var glass = 0, spring = 0
        let gated = FrameClient(owner: "glass", visibleOnly: window, on: scheduler) { _ in glass += 1; return true }
        let always = FrameClient(owner: "drain", isAnimation: false, on: scheduler) { _ in spring += 1; return true }
        gated.activate()
        always.activate()
        window.set(.hidden)
        #expect(scheduler.hasLink && links.invalidated == 0, "a hidden client took the others' link")
        #expect(scheduler.activeClients == ["drain"])
        scheduler.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(glass == 0 && spring == 1)
        gated.deactivate()
        always.deactivate()
    }

    /// A capture vote counts as visible: a screenshot or screen share of a hidden window gets frames.
    @Test func aCaptureVoteTicksAHiddenClient() {
        let links = VisibleOnlyLinks()
        let scheduler = FrameScheduler.testing(mediaTime: { 500 }) { _ in links.make() }
        let window = VisibilityNode(root: "window", own: .hidden)
        var ticks = 0
        let client = FrameClient(owner: "glass", visibleOnly: window, on: scheduler) { _ in ticks += 1; return true }
        client.activate()
        let vote = window.captureVote(reason: "test.screenshot", stayHidden: true)
        #expect(window.wantsFrames && !client.isParked)
        scheduler.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(ticks == 1, "a captured hidden client was not ticked")
        vote.release()
        #expect(!scheduler.hasLink, "the vote's end keeps the link")
        scheduler.frameDidFire(timestamp: 2, refreshInterval: 1.0 / 60)
        #expect(ticks == 1)
        client.deactivate()
    }

    /// A client whose own tick hides its node stops at once; a parked one-shot client that is
    /// deactivated never hears a later flip.
    @Test func hidingInsideATickParksTheClientAndDeactivationStopsWatching() {
        let links = VisibleOnlyLinks()
        let scheduler = FrameScheduler.testing(mediaTime: { 500 }) { _ in links.make() }
        let window = VisibilityNode(root: "window", own: .visible)
        var ticks = 0
        let client = FrameClient(owner: "glass", visibleOnly: window, on: scheduler) { _ in
            ticks += 1
            window.set(.hidden)
            return true
        }
        client.activate()
        scheduler.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(ticks == 1 && client.isParked && !scheduler.hasLink)
        client.deactivate()
        window.set(.visible)
        #expect(!client.isActive && !scheduler.hasLink, "a deactivated client came back on a flip")
        scheduler.frameDidFire(timestamp: 2, refreshInterval: 1.0 / 60)
        #expect(ticks == 1)
    }

    /// A client parked by another client's tick in the same frame does not run, and the ledger counts
    /// no frame wakeup for it: of two clients that each hide their window when they tick, only the
    /// first one ticks and is counted.
    @Test func aClientParkedEarlierInTheFrameIsNotTickedOrCounted() {
        let ledger = WakeupLedger()
        let scheduler = FrameScheduler.testing(ledger: ledger, mediaTime: { 500 }) { _ in VisibleOnlyFakeLink(links: nil) }
        let window = VisibilityNode(root: "window", own: .visible)
        var ticks: [String] = []
        let clients = ["glass.a", "glass.b"].map { owner in
            FrameClient(owner: owner, visibleOnly: window, on: scheduler) { _ in
                ticks.append(owner)
                window.set(.hidden)
                return true
            }
        }
        for client in clients { client.activate() }
        scheduler.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(ticks.count == 1, "a client parked earlier in the frame ticked: \(ticks)")
        let counted = ledger.snapshot().filter { $0.reason == "frame" }
        #expect(counted.map(\.owner) == ticks, "the ledger counted \(counted.map(\.owner)), not the client that ran \(ticks)")
        #expect(counted.map(\.count) == [1])
        for client in clients { client.deactivate() }
    }

    /// A one-shot client re-activated every frame keeps the one watch of its node it made on its first
    /// activation: activation, firing and deactivation do no subscription work, and an idle client
    /// ignores flips. Releasing the client ends the watch.
    @Test func aOneShotClientWatchesItsNodeOnceForItsLife() {
        let scheduler = FrameScheduler.testing(mediaTime: { 500 }) { _ in VisibleOnlyFakeLink(links: nil) }
        let window = VisibilityNode(root: "window", own: .visible)
        var ticks = 0
        var client: FrameClient? = FrameClient(owner: "glass", visibleOnly: window, on: scheduler) { _ in ticks += 1; return false }
        for frame in 1...5 {
            client?.activate()
            let watching = window.subscriberCounts
            #expect(watching.flips == 0 && watching.exemptions == 0 && watching.rendering == 1, "frame \(frame) watches the node \(watching) times")
            scheduler.frameDidFire(timestamp: Double(frame), refreshInterval: 1.0 / 60)
            let afterFire = window.subscriberCounts
            #expect(afterFire.flips == 0 && afterFire.exemptions == 0 && afterFire.rendering == 1, "a one-shot fire dropped its watch: \(afterFire)")
        }
        #expect(ticks == 5)
        window.set(.hidden)
        window.set(.visible)
        #expect(client?.isActive == false && !scheduler.hasLink, "an idle client came back on a flip")
        client?.deactivate()
        client = nil
        let released = window.subscriberCounts
        #expect(released.flips == 0 && released.exemptions == 0 && released.rendering == 0, "a released client still watches its node: \(released)")
    }

    /// A client with no node ticks whatever anyone sees (today's behavior).
    @Test func aClientWithoutANodeIgnoresVisibility() {
        let scheduler = FrameScheduler.testing(mediaTime: { 500 }) { _ in VisibleOnlyFakeLink(links: nil) }
        var ticks = 0
        let client = FrameClient(owner: "spring", on: scheduler) { _ in ticks += 1; return true }
        client.activate()
        #expect(client.visibleOnly == nil && !client.isParked)
        scheduler.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(ticks == 1)
        client.deactivate()
    }
}

/// Counts the links a test scheduler makes and drops.
@MainActor
private final class VisibleOnlyLinks {
    var made = 0
    var invalidated = 0

    func make() -> VisibleOnlyFakeLink {
        made += 1
        return VisibleOnlyFakeLink(links: self)
    }
}

@MainActor
private final class VisibleOnlyFakeLink: FrameLink {
    var isPaused = false
    private weak var links: VisibleOnlyLinks?

    init(links: VisibleOnlyLinks?) { self.links = links }

    func invalidate() { links?.invalidated += 1 }
}
