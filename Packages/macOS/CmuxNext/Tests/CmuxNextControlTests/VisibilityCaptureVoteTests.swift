import CmuxNextWakeups
import Observation
import Testing

/// Capture votes on the visibility tree (VisibilityNode+Capture.swift), after
/// Chromium's `WebContents::IncrementCapturerCount(size, stay_hidden, stay_awake)`: a voted hidden
/// node renders (its frame clients tick, its view observations apply, its task queues run), a
/// `stayHidden` vote keeps page visibility and the timer alignment hidden, and the last release gives
/// one flip and one notice.
@MainActor @Suite(.timeLimit(.minutes(1))) struct VisibilityCaptureVoteTests {
    @Test func aVotedHiddenNodeTicksItsVisibleOnlyClientAndAppliesObservations() {
        let rig = CaptureRig()
        let window = VisibilityNode(root: "window", own: .hidden)
        let tab = VisibilityNode("tab", parent: window)
        var ticks = 0
        let client = FrameClient(owner: "tab.spinner", visibleOnly: tab, on: rig.work.frames) { _ in ticks += 1; return true }
        client.activate()
        var applied: [Int] = []
        let watch = VisibleObservation(tab, owner: "tab.title", on: rig.work) { rig.model.value } apply: { applied.append($0) }
        rig.model.value = 1
        rig.frames(2)
        #expect(ticks == 0 && applied == [0], "a hidden tab rendered")

        let vote = window.captureVote(reason: "agent.screenshot", stayHidden: true)
        #expect(tab.isCaptured && tab.wantsFrames && tab.effective == .hidden)
        #expect(applied == [0, 1], "the vote's turn reads the observation once")
        rig.model.value = 2
        rig.frames(1)
        #expect(ticks == 1, "a captured hidden tab's client was not ticked")
        #expect(applied == [0, 1, 2], "a captured hidden tab's observation did not apply")

        vote.release()
        #expect(!tab.isCaptured && !tab.wantsFrames && client.isParked)
        rig.model.value = 3
        rig.frames(2)
        #expect(ticks == 1 && applied == [0, 1, 2], "a released tab kept rendering")
        watch.cancel()
        client.deactivate()
        rig.stop()
    }

    @Test func aVotedHiddenNodeRunsItsHeldQueue() {
        let rig = CaptureRig()
        let tab = VisibilityNode(root: "tab", own: .hidden)
        let queue = tab.queue(.visible, owner: "Tab.title", on: rig.work)
        var ran = 0
        queue.post(key: "title") { ran += 1 }
        rig.frames(2)
        #expect(ran == 0)
        let vote = tab.captureVote(reason: "agent.screencast", stayHidden: true)
        rig.frames(1)
        #expect(ran == 1, "a captured node held its visible work")
        #expect(queue.runCount(whileNode: .hidden) == 1, "the task ran while the node still read hidden")
        vote.release()
        rig.stop()
    }

    /// Deferred view work (the R-appear and R-hide recipes: a theme recolor, a bar
    /// reload) runs for a capture as a view observation applies for one, so a screenshot of a hidden
    /// tab never shows a stale theme; page visibility stays hidden.
    @Test func aVotedHiddenNodeRunsItsDeferredViewWork() {
        let window = VisibilityNode(root: "window", own: .hidden)
        let tab = VisibilityNode("tab", parent: window)
        var runs: [String] = []
        tab.deferUntilVisible(key: "appearance") { runs.append("missed") }
        #expect(runs.isEmpty && tab.deferredCount == 1)

        let vote = window.captureVote(reason: "agent.screenshot", stayHidden: true)
        #expect(tab.effective == .hidden && tab.wantsFrames)
        #expect(runs == ["missed"] && tab.deferredCount == 0, "a captured tab drew views its deferred work had not updated")
        tab.deferUntilVisible(key: "appearance") { runs.append("now") }
        #expect(runs == ["missed", "now"], "a captured tab held view work")

        vote.release()
        tab.deferUntilVisible(key: "appearance") { runs.append("shown") }
        #expect(runs == ["missed", "now"] && tab.deferredCount == 1, "a released tab did view work")
        window.set(.visible)
        #expect(runs == ["missed", "now", "shown"] && tab.deferredCount == 0)
    }

    @Test func aStayHiddenVoteFlipsNothingAndItsReleaseNotifiesOnce() {
        let node = VisibilityNode(root: "tab", own: .hidden)
        let hiddenSince = node.hiddenSince
        var flips: [Visibility] = []
        var rendering: [Bool] = []
        var exemptions = 0
        let tokens = [
            node.subscribe(owner: "flips") { flips.append($0) },
            node.subscribeRendering(owner: "rendering") { rendering.append($0) },
            node.subscribeExemption(owner: "exemptions") { exemptions += 1 },
        ]
        let first = node.captureVote(reason: "agent.screenshot", stayHidden: true)
        let second = node.captureVote(reason: "agent.screencast", stayHidden: true)
        #expect(node.captureReasons == ["agent.screenshot", "agent.screencast"])
        #expect(node.effective == .hidden && node.hiddenSince == hiddenSince, "a stayHidden vote changed page visibility")
        #expect(flips.isEmpty && rendering == [true] && exemptions == 1)
        first.release()
        #expect(node.wantsFrames && rendering == [true], "a vote is still held")
        second.release()
        second.release()
        #expect(flips.isEmpty && rendering == [true, false] && exemptions == 2)
        #expect(!node.isCaptured && second.isReleased && node.captureReasons.isEmpty)
        _ = tokens
    }

    @Test func aShowingVoteMakesTheNodeVisibleAndItsReleaseGivesOneFlip() {
        let window = VisibilityNode(root: "window", own: .hidden)
        let tab = VisibilityNode("tab", parent: window)
        var flips: [Visibility] = []
        var rendering: [Bool] = []
        let tokens = [
            tab.subscribe(owner: "flips") { flips.append($0) },
            tab.subscribeRendering(owner: "rendering") { rendering.append($0) },
        ]
        let mirror = window.captureVote(reason: "phone.mirror", stayHidden: false)
        let screenshot = window.captureVote(reason: "agent.screenshot", stayHidden: true)
        #expect(window.effective == .visible && tab.isVisible && window.own == .hidden)
        #expect(flips == [.visible] && rendering == [true])
        mirror.release()
        #expect(flips == [.visible, .hidden], "the release gave \(flips.count - 1) flips")
        #expect(rendering == [true], "a stayHidden vote is still held")
        screenshot.release()
        #expect(flips == [.visible, .hidden] && rendering == [true, false])
        _ = tokens
    }

    @Test func aParentVoteReachesOnlyOwnShownChildren() {
        let window = VisibilityNode(root: "window", own: .hidden)
        let pane = VisibilityNode("pane", parent: window)
        let selected = VisibilityNode("tab:selected", parent: pane)
        let unselected = (0..<1000).map { VisibilityNode("tab:\($0)", own: .hidden, parent: pane) }
        var notices = 0
        let tokens = unselected.map { $0.subscribeRendering(owner: "row") { _ in notices += 1 } }
        let vote = window.captureVote(reason: "screen.share", stayHidden: true)
        #expect(pane.isCaptured && selected.isCaptured && selected.wantsFrames)
        #expect(unselected.allSatisfy { !$0.isCaptured && $0.visits == 0 } && notices == 0, "an unselected tab was captured")

        let late = VisibilityNode("tab:new", parent: pane)
        #expect(late.isCaptured, "a child made under a captured parent starts captured")
        late.set(.hidden)
        #expect(!late.isCaptured)
        selected.detach()
        #expect(!selected.isCaptured && selected.effective == .hidden)
        vote.release()
        #expect(!pane.isCaptured && !window.wantsFrames)
        _ = tokens
    }
}

/// The observed model.
@MainActor @Observable
private final class CaptureModel {
    var value = 0
}

/// A scheduler on a fake link kept up by a frame client, so posts wait for hand-fired frames.
@MainActor
private final class CaptureRig {
    let work: MainWorkScheduler
    let model = CaptureModel()
    private let clock: CaptureClock
    private var timestamp: Double = 1
    private let keeper: FrameClient

    init() {
        let clock = CaptureClock()
        self.clock = clock
        work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: { clock.now })) { _ in CaptureFakeLink() }
        keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        keeper.activate()
    }

    /// Fires `count` frames, 17 ms apart.
    func frames(_ count: Int) {
        for _ in 0..<count {
            clock.now += 17_000_000
            timestamp += 1.0 / 60
            work.frameDidFire(timestamp: timestamp, refreshInterval: 1.0 / 60)
        }
    }

    func stop() { keeper.deactivate() }
}

/// A clock the rig moves (`CLOCK_UPTIME_RAW` nanoseconds).
@MainActor
private final class CaptureClock {
    var now: UInt64 = 1_000_000_000
}

@MainActor
private final class CaptureFakeLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
