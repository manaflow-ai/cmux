import AppKit
@testable import CmuxNextBrowser
import Testing

/// Task p01-process-052: a hosted page's resize goes to the Chromium Host with one Core Animation fence
/// per window per turn, held for one display frame at most from the turn's commit, and the main thread
/// never waits on it.
/// The host's side (the fence taken by its seq, the fork's join before the frame change) is
/// ChromiumHost/tests/host_resize_test.cpp; the WindowServer's hold is cef-resize-sync-bench.py on the fleet.
@MainActor
@Suite struct ChromiumHostResizeFenceTests {
    /// The wire: each resize, and the answers the test gives.
    final class Wire: ChromiumHostPageResizeWire {
        struct Sent: Equatable {
            let view: UInt64
            let browser: Int32
            let width: Int32
            let height: Int32
            let fence: mach_port_t
            let deadlineFrames: UInt32
        }

        var sent: [Sent] = []
        /// What the next sends return (`.fenced` takes the next reply token); empty: fenced when a fence came.
        var outcomes: [ChromiumHostResizeFence.Send] = []
        var deadlines: [Duration] = []
        var answers: [UInt32: (Bool?) -> Void] = [:]
        private var nextReply: UInt32 = 0

        func resize(view: UInt64, browser: Int32, width: Int32, height: Int32, fence: mach_port_t,
                    deadlineFrames: UInt32) -> ChromiumHostResizeFence.Send {
            sent.append(Sent(view: view, browser: browser, width: width, height: height, fence: fence,
                             deadlineFrames: deadlineFrames))
            if !outcomes.isEmpty { return outcomes.removeFirst() }
            guard fence != 0 else { return .unfenced }
            nextReply += 1
            return .fenced(reply: nextReply)
        }

        func whenAnswered(_ reply: UInt32, within deadline: Duration, then: @escaping (Bool?) -> Void) {
            deadlines.append(deadline)
            answers[reply] = then
        }

        func answer(_ reply: UInt32, _ joined: Bool?) {
            answers.removeValue(forKey: reply)?(joined)
        }
    }

    /// Fences: each window's port, what was held, ended and released.
    final class Fences: ChromiumHostFenceMaking {
        var made: [mach_port_t] = []
        var held: [mach_port_t] = []
        var released: [mach_port_t] = []
        var ended = 0
        var unavailable = false
        var onRelease: ((mach_port_t) -> Void)?
        private var next: mach_port_t = 0x100

        func makeFence(for window: NSWindow) -> ChromiumHostFence? {
            guard !unavailable else { return nil }
            next += 1
            made.append(next)
            return ChromiumHostFence(port: next, hold: { [unowned self] in self.held.append($0) },
                                     invalidate: { [unowned self] in self.ended += 1 },
                                     release: { [unowned self] in
                                         self.released.append($0)
                                         self.onRelease?($0)
                                     })
        }
    }

    /// The turn's commit, run by the test.
    final class Commits: ChromiumHostCommitObserving {
        var waiting: [@MainActor () -> Void] = []
        func afterCommit(_ body: @escaping @MainActor () -> Void) { waiting.append(body) }
        func commit() {
            let bodies = waiting
            waiting.removeAll()
            for body in bodies { body() }
        }
    }

    /// A commit whose completion runs inside `afterCommit`: no transaction was open in the turn.
    final class CommitsAtOnce: ChromiumHostCommitObserving {
        var ran = 0
        func afterCommit(_ body: @escaping @MainActor () -> Void) {
            ran += 1
            body()
        }
    }

    /// The deadline queue: each delay asked for, fired by the test.
    final class Deadlines: ChromiumHostFenceDeadlines {
        var delays: [Duration] = []
        var waiting: [@MainActor @Sendable () -> Void] = []
        func after(_ delay: Duration, _ body: @escaping @MainActor @Sendable () -> Void) {
            delays.append(delay)
            waiting.append(body)
        }
        func fire() {
            let bodies = waiting
            waiting.removeAll()
            for body in bodies { body() }
        }
    }

    /// Uptime nanoseconds the test moves.
    final class Uptime {
        var value: UInt64 = 1_000_000_000
    }

    let wire = Wire()
    let fences = Fences()
    let commits = Commits()
    let deadlines = Deadlines()
    let uptime = Uptime()

    func coordinator(commits: (any ChromiumHostCommitObserving)? = nil, fenced: Bool = true) -> ChromiumHostResizeFence {
        ChromiumHostResizeFence(wire: wire, fences: fenced ? fences : nil, commits: commits ?? self.commits,
                                deadlines: deadlines, now: { [uptime] in uptime.value })
    }

    func geometry(_ width: CGFloat, _ height: CGFloat) -> ChromiumHostGeometry {
        ChromiumHostGeometry(screenRect: CGRect(x: 10, y: 20, width: width, height: height), scale: 2)
    }

    func window() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
    }

    @Test func oneFencePerWindowPerTurnHeldOnceReleasedAtTheCommit() {
        let resizes = coordinator()
        let first = window()
        let second = window()
        resizes.resize(view: 1, browser: 7, geometry: geometry(300, 200), in: first)
        resizes.resize(view: 2, browser: 8, geometry: geometry(100, 200), in: first)
        resizes.resize(view: 3, browser: 9, geometry: geometry(500, 200), in: second)
        #expect(fences.made == [0x101, 0x102])
        #expect(wire.sent.map(\.fence) == [0x101, 0x101, 0x102])
        #expect(wire.sent.map(\.deadlineFrames) == [1, 1, 1])
        #expect(fences.held == [0x101, 0x102])
        #expect(commits.waiting.count == 1)
        #expect(fences.released.isEmpty)
        commits.commit()
        #expect(Set(fences.released) == [0x101, 0x102])
        #expect(resizes.stats.fenced == 3 && resizes.stats.fencedTurns == 2)

        // The next turn makes a new fence.
        resizes.resize(view: 1, browser: 7, geometry: geometry(310, 200), in: first)
        #expect(fences.made == [0x101, 0x102, 0x103])
        commits.commit()
        #expect(fences.released.last == 0x103)
    }

    @Test func onlyAChangedSizeIsSentAndAnUnsentOneIsTriedAgain() {
        let resizes = coordinator(fenced: false)
        resizes.resize(view: 1, browser: 7, geometry: geometry(300, 200), in: nil)
        resizes.resize(view: 1, browser: 7, geometry: ChromiumHostGeometry(screenRect: CGRect(x: 90, y: 90, width: 300, height: 200), scale: 2),
                       in: nil)
        #expect(wire.sent.count == 1)  // a move is not a resize
        wire.outcomes = [.notSent]
        resizes.resize(view: 1, browser: 7, geometry: geometry(320, 200), in: nil)
        resizes.resize(view: 1, browser: 7, geometry: geometry(320, 200), in: nil)
        #expect(wire.sent.map(\.width) == [300, 320, 320])
        resizes.resize(view: 0, browser: 7, geometry: geometry(10, 10), in: nil)
        resizes.resize(view: 1, browser: 7, geometry: geometry(0, 10), in: nil)
        #expect(wire.sent.count == 3)
        #expect(resizes.stats.resizes == 2 && resizes.stats.fenced == 0)
        #expect(commits.waiting.isEmpty)
    }

    @Test func featureOffOrNoContextSendsEveryResizeUnfenced() {
        fences.unavailable = true
        let resizes = coordinator()
        resizes.resize(view: 1, browser: 7, geometry: geometry(300, 200), in: window())
        #expect(wire.sent.map(\.fence) == [0])
        #expect(fences.held.isEmpty && commits.waiting.isEmpty)
    }

    @Test func aFenceTheHostCouldNotSendIsNotHeld() {
        let resizes = coordinator()
        wire.outcomes = [.unfenced]
        resizes.resize(view: 1, browser: 7, geometry: geometry(300, 200), in: window())
        #expect(fences.made == [0x101])
        #expect(fences.held.isEmpty)  // nothing would release it: the commit would wait the system's limit
        commits.commit()
        #expect(fences.released == [0x101])
    }

    @Test func aLateHostEndsTheWindowsFencesAndTheDeadlineIsOneFrame() {
        let resizes = coordinator()
        resizes.resize(view: 1, browser: 7, geometry: geometry(300, 200), in: window())
        resizes.resize(view: 2, browser: 8, geometry: geometry(300, 200), in: window())
        resizes.resize(view: 3, browser: 9, geometry: geometry(300, 200), in: window())
        #expect(wire.deadlines.count == 3)
        // A window not on a screen takes a 60 Hz frame.
        #expect(wire.deadlines.allSatisfy { $0 == CEFResizeSyncDeadline.defaultFrame })
        wire.answer(1, true)
        wire.answer(2, false)
        wire.answer(3, nil)
        #expect(resizes.stats.joined == 1 && resizes.stats.refused == 1 && resizes.stats.late == 1)
        #expect(fences.ended == 1)
    }

    @Test func theCommitReleasesTheRightsEvenWhenTheCoordinatorWent() {
        var resizes: ChromiumHostResizeFence? = coordinator()
        resizes?.resize(view: 1, browser: 7, geometry: geometry(300, 200), in: window())
        resizes = nil
        commits.commit()
        #expect(fences.released == [0x101])
    }

    /// With no transaction open in the turn, the commit's completion runs inside `afterCommit`: cmux's
    /// right goes only after the resize sent its copy and held the commit on it.
    @Test func aCommitThatCompletesAtOnceReleasesTheRightAfterTheSend() {
        let atOnce = CommitsAtOnce()
        let resizes = coordinator(commits: atOnce)
        let shown = window()
        var sentWhenReleased: [Int] = []
        fences.onRelease = { [wire] _ in sentWhenReleased.append(wire.sent.count) }
        resizes.resize(view: 1, browser: 7, geometry: geometry(300, 200), in: shown)
        #expect(wire.sent.map(\.fence) == [0x101])
        #expect(fences.held == [0x101])
        #expect(fences.released == [0x101] && sentWhenReleased == [1])
        // The next resize in the same main-thread turn holds the next commit on a fence of its own.
        resizes.resize(view: 1, browser: 7, geometry: geometry(310, 200), in: shown)
        #expect(fences.made == [0x101, 0x102] && fences.held == [0x101, 0x102])
        #expect(fences.released == [0x101, 0x102] && sentWhenReleased == [1, 2])
        #expect(atOnce.ran == 2)
    }

    /// The fork's frame counts from its join: a host that joins after the turn's commit has the window's
    /// fences ended one frame after that commit, not one frame after the join.
    @Test func aJoinAfterTheCommitIsCutOneFrameAfterTheCommit() {
        let resizes = coordinator()
        resizes.resize(view: 1, browser: 7, geometry: geometry(300, 200), in: window())
        uptime.value += 2_000_000
        commits.commit()
        uptime.value += 5_000_000
        wire.answer(1, true)
        #expect(deadlines.delays == [CEFResizeSyncDeadline.defaultFrame - .milliseconds(5)])
        #expect(fences.ended == 0)
        deadlines.fire()
        #expect(fences.ended == 1)
        #expect(resizes.stats.joined == 1 && resizes.stats.cut == 1)
    }

    @Test func aJoinBeforeTheCommitNeedsNoCut() {
        let resizes = coordinator()
        resizes.resize(view: 1, browser: 7, geometry: geometry(300, 200), in: window())
        wire.answer(1, true)
        commits.commit()
        #expect(deadlines.delays.isEmpty && fences.ended == 0)
        #expect(resizes.stats.joined == 1 && resizes.stats.cut == 0)
    }

    /// A newer turn of the window holds a fence: ending the context's fences would cut its page short.
    @Test func aCutLeavesANewerTurnOfTheWindowAlone() {
        let resizes = coordinator()
        let shown = window()
        resizes.resize(view: 1, browser: 7, geometry: geometry(300, 200), in: shown)
        commits.commit()
        resizes.resize(view: 1, browser: 7, geometry: geometry(320, 200), in: shown)
        wire.answer(1, true)
        deadlines.fire()
        #expect(fences.ended == 0 && resizes.stats.cut == 0)
        // That turn joined after its own commit: its cut ends the window's fences.
        commits.commit()
        wire.answer(2, true)
        deadlines.fire()
        #expect(fences.ended == 1 && resizes.stats.cut == 1)
    }

    /// A page window the host opened since (a new browser on the view's token) takes the size again; the
    /// same size changes no frame, so nothing is fenced.
    @Test func aResendOfAnUnchangedSizeGoesUnfenced() {
        let resizes = coordinator()
        let shown = window()
        resizes.resize(view: 1, browser: 7, geometry: geometry(300, 200), in: shown)
        commits.commit()
        resizes.resize(view: 1, browser: 8, geometry: geometry(300, 200), in: shown)
        #expect(wire.sent.count == 1)
        resizes.resize(view: 1, browser: 8, geometry: geometry(300, 200), in: shown, resend: true)
        #expect(wire.sent.map(\.fence) == [0x101, 0])
        #expect(wire.sent.map(\.browser) == [7, 8])
        #expect(fences.made == [0x101] && commits.waiting.isEmpty)
    }

    @Test(arguments: [(1.0 / 60, 16_667), (1.0 / 120, 8_334), (0.0, 16_667), (-1.0, 16_667)])
    func fenceDeadlineIsOneFrameOfTheScreen(refresh: Double, microseconds: Int) {
        #expect(CEFResizeSyncDeadline.fenceDeadline(refreshInterval: refresh) == .microseconds(microseconds))
        #expect(CEFResizeSyncDeadline.fenceFrames == 1)
    }
}
