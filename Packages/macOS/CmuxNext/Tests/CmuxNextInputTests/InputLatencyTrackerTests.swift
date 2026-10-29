import AppKit
import Atomics
@testable import CmuxNextInput
import CmuxNextInputCore
import CmuxNextSignposts
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import CoreFoundation
import Darwin
import Testing

/// InputLatencyTracker: stage order through a fake commit boundary and presentation clock, one
/// boundary per turn, a terminal key that closes at its own content frame, the no-echo deadline, the estimate's basis
/// and variable-refresh label, missed commits, refused late marks, the half-ring batch, and no allocation per event
/// with the real boundary and PresentationClock.
@MainActor
@Suite(.serialized) struct InputLatencyTrackerTests {
    /// A commit boundary the test fires, as the run loop does after Core Animation's commit.
    @MainActor
    final class FakeBoundary: InputTurnBoundary {
        private var handler: (@MainActor (CommitBoundary.Outcome) -> Void)?
        private(set) var isArmed = false
        /// Arms since the last fire.
        private(set) var requests = 0

        func start(_ handler: @escaping @MainActor (CommitBoundary.Outcome) -> Void) { self.handler = handler }

        func arm() {
            guard !isArmed else { return }
            isArmed = true
            requests += 1
        }

        /// Runs an armed boundary; nothing when the tracker did not arm it.
        func fire(_ outcome: CommitBoundary.Outcome) {
            guard isArmed else { return }
            isArmed = false
            requests = 0
            handler?(outcome)
        }
    }

    /// A presentation clock that answers content time + 1 ms with a chosen basis, at once (no running link) or at
    /// ``tick()`` (a held link), and counts link holds.
    @MainActor
    final class FakePresentation: InputPresentationEstimating {
        static let renderServerNanos: UInt64 = 1_000_000
        var holds = 0
        var asked: [UInt64] = []
        var basis: PresentedEstimate.Basis = .heldVsync
        var isVariableRefresh = false
        var waitsForTick = false
        private var queued: [(nanos: UInt64, resolve: PresentationClock.Resolve)] = []

        func holdLinkForInput(in window: NSWindow?) { holds += 1 }

        func presented(committedAt nanos: UInt64, in window: NSWindow?, _ resolve: @escaping PresentationClock.Resolve) {
            asked.append(nanos)
            if waitsForTick { queued.append((nanos, resolve)) } else { resolve(estimate(nanos)) }
        }

        /// The held link's next tick: resolves what waits, oldest first.
        func tick() {
            let waiting = queued
            queued.removeAll()
            for entry in waiting { entry.resolve(estimate(entry.nanos)) }
        }

        private func estimate(_ nanos: UInt64) -> PresentedEstimate {
            PresentedEstimate(nanos: nanos + Self.renderServerNanos, basis: basis, refreshNanos: 16_666_667,
                              isVariableRefresh: isVariableRefresh)
        }
    }

    /// The parts of a tracker a test drives: its clock, its boundary, the slots it emitted.
    @MainActor
    final class Harness {
        let clock = ManagedAtomic<UInt64>(1_000_000_000)
        let presentation = FakePresentation()
        let boundary = FakeBoundary()
        var emitted: [InputLatencySlot] = []
        var batches: [[InputLatencySlot]] = []
        private(set) var tracker: InputLatencyTracker!

        init(ringCapacity: Int = 256, batches wantsBatches: Bool = false,
             frameIntervals: (any InputFrameIntervals)? = nil) {
            let clock = clock
            tracker = InputLatencyTracker(
                table: InputLatencySlotTable(), ring: InputLatencyRing(capacity: ringCapacity), presentation: presentation,
                boundary: boundary, emit: { [weak self] slot in self?.emitted.append(slot) },
                batchSink: wantsBatches ? { [weak self] batch in self?.batches.append(batch) } as InputLatencyTracker.BatchSink : nil,
                frameIntervals: frameIntervals, now: { clock.load(ordering: .relaxed) })
        }

        var now: UInt64 { clock.load(ordering: .relaxed) }

        /// Moves the clock `nanos` ahead and returns the new time.
        @discardableResult
        func advance(_ nanos: UInt64) -> UInt64 {
            clock.wrappingIncrementThenLoad(by: nanos, ordering: .relaxed)
        }

        /// Ends the main run-loop turn: the boundary the tracker armed fires.
        func commit(_ outcome: CommitBoundary.Outcome = .committed) {
            boundary.fire(outcome)
        }

        /// Ends the turn, then lets every slot that waits for its target's frame (a terminal's, a page's, an agent
        /// pane's) pass its deadline and close at the next turn, with no presented time.
        func settle() {
            commit()
            advance(InputLatencyTracker.contentDeadlineNanos + 1)
            commit()
        }
    }

    private func begin(_ harness: Harness, kind: InputEventKind = .keyPress, target: InputTarget = .textView,
                       ageNanos: UInt64 = 2_000_000, arrivedAgoNanos: UInt64? = nil) -> InputLatencyToken? {
        let now = harness.now
        return harness.tracker.begin(kind: kind, target: target, entrypoint: .person,
                                     eventTimestamp: TimeInterval(now - ageNanos) / 1e9, window: nil,
                                     arrivedMain: arrivedAgoNanos.map { now - $0 })
    }

    @Test("A view key's stages close in order at the turn's commit, presented from the commit")
    func stagesCloseInOrder() throws {
        let harness = Harness()
        let token = try #require(begin(harness, arrivedAgoNanos: 500_000))
        #expect(harness.presentation.holds == 1)
        harness.advance(100_000)
        #expect(harness.tracker.mark(token, .textInputStart))
        harness.advance(300_000)
        #expect(harness.tracker.mark(token, .textInputEnd))
        harness.advance(200_000)
        harness.tracker.endDispatch(token)
        harness.advance(2_000_000)
        #expect(harness.emitted.isEmpty, "the slot waits for the commit")
        harness.commit()

        let slot = try #require(harness.emitted.first)
        #expect(harness.emitted.count == 1)
        #expect(slot.kind == .keyPress && slot.target == .textView && slot.entrypoint == .person)
        #expect(slot.presentationSource == .estimatedVsync && !slot.isVariableRefresh)
        let order: [InputStage] = [.generated, .arrivedMain, .dispatchStart, .textInputStart, .textInputEnd,
                                   .dispatchEnd, .mainCommit, .presented]
        for stage in order { #expect(slot.reached(stage), "\(stage)") }
        for (earlier, later) in zip(order, order.dropFirst()) {
            #expect(slot[earlier] <= slot[later], "\(earlier) before \(later)")
        }
        #expect(slot.nanos(from: .generated, to: .arrivedMain) == 1_500_000)
        #expect(slot.nanos(from: .arrivedMain, to: .dispatchStart) == 500_000)
        #expect(slot.nanos(from: .mainCommit, to: .presented) == FakePresentation.renderServerNanos)
        #expect(harness.presentation.asked == [slot.mainCommit])
        for skipped: InputStage in [.lastGenerated, .contentSubmitted, .daemonReceived, .ptyWritten, .echoRead,
                                    .echoSent] {
            #expect(!slot.reached(skipped), "\(skipped)")
        }
        #expect(harness.tracker.closedCount == 1)
    }

    @Test("arrivedMain is stamped only when the caller knows it, so it never reads as a zero queue wait")
    func arrivedMainOnlyWhenKnown() throws {
        let harness = Harness()
        _ = try #require(begin(harness))
        _ = try #require(begin(harness, arrivedAgoNanos: 400_000))
        let future = harness.now + 1_000_000
        _ = try #require(harness.tracker.begin(kind: .keyPress, target: .textView, entrypoint: .person,
                                               eventTimestamp: 0, window: nil, arrivedMain: future))
        harness.commit()
        #expect(harness.emitted.count == 3)
        let unknown = harness.emitted[0]
        #expect(!unknown.reached(.arrivedMain) && unknown.reached(.dispatchStart))
        let known = harness.emitted[1]
        #expect(known.nanos(from: .generated, to: .arrivedMain) == 1_600_000)
        #expect(known.nanos(from: .arrivedMain, to: .dispatchStart) == 400_000)
        #expect(!harness.emitted[2].reached(.arrivedMain), "an arrival after the dispatch start is not a reading")
    }

    @Test("Every view slot opened in one turn closes at that turn's one boundary")
    func oneBoundaryPerTurn() throws {
        let harness = Harness()
        let first = try #require(begin(harness))
        let second = try #require(begin(harness, kind: .mousePress, target: .sidebar))
        let third = try #require(begin(harness, kind: .scrollFirstUpdate, target: .layout))
        #expect(harness.boundary.requests == 1)
        for token in [first, second, third] { harness.tracker.endDispatch(token) }
        harness.commit()
        #expect(harness.emitted.map(\.kind) == [.keyPress, .mousePress, .scrollFirstUpdate])
        #expect(harness.tracker.pendingCount == 0)
        #expect(!harness.boundary.isArmed, "nothing waits, so no boundary is armed")

        _ = try #require(begin(harness))
        #expect(harness.boundary.requests == 1, "the next turn arms its own boundary")
    }

    /// Holds a tracker whose emit callback opens another slot on that same tracker.
    @MainActor
    final class Reopener {
        var tracker: InputLatencyTracker?
        var reopened: InputLatencyToken?
    }

    @Test("A slot opened while the turn's slots close waits for the next boundary")
    func slotOpenedDuringCloseWaitsForTheNextBoundary() throws {
        let harness = Harness()
        let box = Reopener()
        let tracker = InputLatencyTracker(
            table: InputLatencySlotTable(), ring: InputLatencyRing(), presentation: harness.presentation,
            boundary: harness.boundary,
            emit: { slot in
                harness.emitted.append(slot)
                guard box.reopened == nil else { return }
                box.reopened = box.tracker?.begin(kind: .mousePress, target: .layout, entrypoint: .person,
                                                  eventTimestamp: 0, window: nil)
            },
            batchSink: nil, now: { 2_000_000_000 })
        box.tracker = tracker
        _ = try #require(tracker.begin(kind: .keyPress, target: .textView, entrypoint: .person, eventTimestamp: 0,
                                       window: nil))
        harness.commit()
        #expect(harness.emitted.map(\.kind) == [.keyPress])
        #expect(box.reopened != nil)
        #expect(tracker.pendingCount == 1, "the reopened slot waits")
        #expect(harness.boundary.isArmed && harness.boundary.requests == 1, "and armed the next boundary")
        harness.commit()
        #expect(harness.emitted.map(\.kind) == [.keyPress, .mousePress])
        #expect(tracker.pendingCount == 0)
    }

    @Test("A missed commit closes a view slot with its commit and presented stages skipped")
    func missedCommitSkipsPresented() throws {
        let harness = Harness()
        let token = try #require(begin(harness))
        harness.tracker.endDispatch(token)
        harness.commit(.missed)
        let slot = try #require(harness.emitted.first)
        #expect(slot.reached(.dispatchEnd))
        #expect(!slot.reached(.mainCommit) && !slot.reached(.presented))
        #expect(slot.totalNanos == nil)
        #expect(harness.presentation.asked.isEmpty)
    }

    @Test("A mark after a view slot closed misses it, and a stage is written once")
    func lateAndRepeatedMarksAreRefused() throws {
        let harness = Harness()
        let token = try #require(begin(harness))
        #expect(harness.tracker.mark(token, .textInputStart))
        #expect(!harness.tracker.mark(token, .textInputStart), "written once")
        #expect(harness.tracker.markCausedFrameUpdate(token))
        harness.commit()
        #expect(!harness.tracker.mark(token, .textInputEnd), "the slot closed at its commit")
        let slot = try #require(harness.emitted.first)
        #expect(slot.causedFrameUpdate)
        #expect(!slot.reached(.textInputEnd))
    }

    @Test("A terminal key stays open past its turn's commit and closes at the frame that shows its echo")
    func terminalKeyClosesAtItsContentFrame() async throws {
        let harness = Harness()
        let token = try #require(begin(harness, target: .terminal))
        harness.tracker.endDispatch(token)
        let commitEnd = harness.advance(1_000_000)
        harness.commit()
        #expect(harness.emitted.isEmpty, "a terminal key's frame comes after the app's commit")
        #expect(harness.tracker.waitingCount == 1)
        #expect(harness.boundary.isArmed, "the next turn checks the waiting slot")

        let tracker = harness.tracker!
        let stages: [(offset: UInt64, stage: InputStage)] = [(1, .daemonReceived), (2, .ptyWritten), (3, .echoRead),
                                                             (4, .echoSent), (5, .contentSubmitted)]
        await withTaskGroup(of: Void.self) { group in
            for entry in stages {
                group.addTask { @Sendable in
                    _ = tracker.mark(token, entry.stage, at: commitEnd + entry.offset * 1_000_000)
                }
            }
        }
        harness.advance(6_000_000)
        harness.commit()

        let slot = try #require(harness.emitted.first)
        #expect(harness.emitted.count == 1)
        #expect(slot.mainCommit == commitEnd)
        for entry in stages { #expect(slot[entry.stage] == commitEnd + entry.offset * 1_000_000, "\(entry.stage)") }
        #expect(slot.presented > slot.contentSubmitted)
        #expect(slot.nanos(from: .contentSubmitted, to: .presented) == FakePresentation.renderServerNanos)
        #expect(harness.presentation.asked == [slot.contentSubmitted], "presented is the submission's estimate")
        #expect(harness.tracker.waitingCount == 0 && !harness.boundary.isArmed)
    }

    @Test("A key press is the dispatching key from its begin to its dispatch end; a release never is")
    func dispatchingKeyFollowsTheKeyPress() throws {
        let harness = Harness()
        #expect(harness.tracker.dispatchingKey == nil)
        let press = try #require(begin(harness, target: .terminal))
        #expect(harness.tracker.dispatchingKey == press)
        harness.tracker.endDispatch(press)
        #expect(harness.tracker.dispatchingKey == nil)
        let release = try #require(begin(harness, kind: .keyRelease, target: .terminal))
        #expect(harness.tracker.dispatchingKey == nil)
        harness.tracker.endDispatch(release)
        harness.settle()
    }

    @Test("A terminal key takes the daemon's stages its echo carries, by the key's flow (p04-input-094)")
    func terminalKeyTakesTheDaemonsStages() throws {
        let harness = Harness()
        let token = try #require(begin(harness, target: .terminal))
        let start = try #require(harness.tracker.table.time(token, .dispatchStart))
        harness.tracker.endDispatch(token)
        harness.commit()
        let stamps = TerminalKeyStamps(received: start + 1_000_000, written: start + 1_100_000, read: start + 3_000_000,
                                       sent: start + 3_100_000)
        #expect(InputLatencyToken(keyFlow: token.keyFlow) == token)
        #expect(harness.tracker.keyEchoStamped(flow: token.keyFlow, stamps, decodedAt: start + 3_300_000))
        #expect(harness.tracker.mark(token, .echoParsed, at: start + 3_500_000))
        #expect(harness.tracker.mark(token, .contentSubmitted, at: start + 4_000_000))
        harness.advance(5_000_000)
        harness.commit()

        let slot = try #require(harness.emitted.first)
        #expect(slot.daemonReceived == stamps.received && slot.ptyWritten == stamps.written)
        #expect(slot.echoRead == stamps.read && slot.echoSent == stamps.sent)
        #expect(slot.echoParsed == start + 3_500_000)
        var ledger = InputLatencyLedger()
        ledger.fold(InputLatencyBatch(slots: [slot], vsyncNanos: 16_666_667))
        let row = try #require(ledger.rows.values.first)
        #expect(row[.daemonReceived].maxNanos == stamps.received - slot.dispatchEnd, "the daemon's delta, after dispatch")
        #expect(row[.echoParsed].maxNanos == 400_000, "the app's parse, after the daemon sent the echo")
        #expect(row[.contentSubmitted].maxNanos == 500_000, "the frame, after the parse")
    }

    @Test("Daemon stamps on another clock, out of order, or for no slot are refused")
    func foreignDaemonStampsAreRefused() throws {
        let harness = Harness()
        let token = try #require(begin(harness, target: .terminal))
        let start = try #require(harness.tracker.table.time(token, .dispatchStart))
        let decoded = start + 10_000_000
        let tracker = harness.tracker!
        // Another machine's uptime: before the key.
        #expect(!tracker.keyEchoStamped(flow: token.keyFlow, TerminalKeyStamps(received: 5, written: 6, read: 7, sent: 8),
                                        decodedAt: decoded))
        // After the echo was decoded.
        #expect(!tracker.keyEchoStamped(flow: token.keyFlow, TerminalKeyStamps(received: decoded + 1, written: 0, read: 0,
                                                                               sent: 0), decodedAt: decoded))
        // Out of order.
        #expect(!tracker.keyEchoStamped(flow: token.keyFlow, TerminalKeyStamps(received: start + 3, written: start + 2,
                                                                               read: start + 4, sent: start + 5),
                                        decodedAt: decoded))
        // A typing-probe flow (a pid in the high bits) names no slot.
        #expect(!tracker.keyEchoStamped(flow: 0x1234 << 32 | UInt64(token.rawValue),
                                        TerminalKeyStamps(received: start + 1, written: 0, read: 0, sent: 0), decodedAt: decoded))
        #expect(tracker.table.time(token, .daemonReceived) == nil)
        harness.settle()
    }

    @Test("A terminal key with no frame by the deadline closes with presented skipped (no echo)")
    func noEchoByTheDeadline() throws {
        let harness = Harness()
        _ = try #require(begin(harness, target: .terminal))
        harness.commit()
        harness.advance(InputLatencyTracker.contentDeadlineNanos)
        harness.commit()
        #expect(harness.emitted.isEmpty, "the deadline itself still counts")
        harness.advance(1)
        harness.commit()
        let slot = try #require(harness.emitted.first)
        #expect(slot.reached(.mainCommit) && !slot.reached(.presented) && slot.totalNanos == nil)

        let late = try #require(begin(harness, kind: .keyRelease, target: .terminal))
        let commitEnd = harness.now
        harness.commit()
        harness.tracker.mark(late, .contentSubmitted, at: commitEnd + InputLatencyTracker.contentDeadlineNanos + 1)
        harness.commit()
        let lateSlot = try #require(harness.emitted.last)
        #expect(lateSlot.kind == .keyRelease && lateSlot.reached(.contentSubmitted) && !lateSlot.reached(.presented))
        #expect(harness.presentation.asked.isEmpty)
        #expect(harness.tracker.waitingCount == 0)
    }

    @Test("A page whose host reports the presented time keeps that time and source")
    func hostFeedbackIsKept() throws {
        let harness = Harness()
        harness.tracker.pagesReportPresentation = true
        let token = try #require(begin(harness, kind: .mousePress, target: .chromiumPage))
        harness.commit()
        let shown = harness.advance(9_000_000)
        #expect(harness.tracker.table.setPresentationSource(token, .hostFeedback))
        #expect(harness.tracker.mark(token, .presented, at: shown))
        harness.commit()
        let slot = try #require(harness.emitted.first)
        #expect(slot.presented == shown && slot.presentationSource == .hostFeedback)
        #expect(harness.presentation.asked.isEmpty)
    }

    @Test("The estimate's basis and variable refresh label the slot, the signpost and the trace point")
    func estimateBasisLabelsTheSlot() throws {
        let expected: [(basis: PresentedEstimate.Basis, source: InputPresentationSource)] = [
            (.heldVsync, .estimatedVsync), (.extrapolated, .extrapolatedVsync), (.nominal, .nominalRefresh),
        ]
        var sources: Set<InputPresentationSource> = []
        for entry in expected {
            let harness = Harness()
            harness.presentation.basis = entry.basis
            harness.presentation.isVariableRefresh = entry.basis == .nominal
            _ = try #require(begin(harness))
            harness.commit()
            let slot = try #require(harness.emitted.first)
            #expect(slot.presentationSource == entry.source, "\(entry.basis)")
            #expect(slot.isVariableRefresh == (entry.basis == .nominal))
            let message = InputLatencySignpostMessage(slot: slot)
            #expect(message.presentationSource == entry.source.rawValue)
            #expect(message.variableRefresh == slot.isVariableRefresh)
            #expect((message.traceArg0 >> 33) & 1 == (slot.isVariableRefresh ? 1 : 0))
            sources.insert(slot.presentationSource)
        }
        #expect(sources.count == 3, "a nominal guess and a held vsync never look the same")
    }

    @Test("Slots wait for the held link's tick and close in the order they were asked")
    func presentedWaitsForTheTick() throws {
        let harness = Harness()
        harness.presentation.waitsForTick = true
        _ = try #require(begin(harness))
        _ = try #require(begin(harness, kind: .mousePress, target: .sidebar))
        harness.commit()
        #expect(harness.emitted.isEmpty && harness.tracker.pendingCount == 0)
        harness.presentation.tick()
        #expect(harness.emitted.map(\.kind) == [.keyPress, .mousePress])
    }

    @Test("Each half ring of closed slots goes to the batch sink, oldest first")
    func halfRingGoesToTheSink() throws {
        let harness = Harness(ringCapacity: 8, batches: true)
        for turn in 0..<3 {
            for _ in 0..<3 { _ = try #require(begin(harness, target: turn == 0 ? .sidebar : .textView)) }
            harness.commit()
        }
        #expect(harness.batches.map(\.count) == [4, 4])
        #expect(harness.batches.first?.first?.target == .sidebar)
        #expect(harness.tracker.recent(1).first?.target == .textView)
    }

    @Test("An event timestamp of 0 or later than now opens the slot at now")
    func generatedNeverAfterArrival() {
        #expect(InputLatencyTracker.generatedNanos(eventTimestamp: 0, arrived: 5_000) == 5_000)
        #expect(InputLatencyTracker.generatedNanos(eventTimestamp: 10, arrived: 5_000) == 5_000)
        #expect(InputLatencyTracker.generatedNanos(eventTimestamp: 1, arrived: 3_000_000_000) == 1_000_000_000)
    }

    @Test("The input.latency message carries microsecond offsets, -1 for a skipped stage")
    func signpostMessageFields() {
        var slot = InputLatencySlot(kind: .scrollFirstUpdate, target: .chromiumPage, entrypoint: .automation,
                                    presentationSource: .hostFeedback, causedFrameUpdate: true, isVariableRefresh: true,
                                    coalescedCount: 3)
        slot.generated = 10_000_000
        slot.dispatchStart = 10_250_000
        slot.presented = 18_000_000
        let message = InputLatencySignpostMessage(slot: slot)
        #expect(message.kind == InputEventKind.scrollFirstUpdate.rawValue)
        #expect(message.target == InputTarget.chromiumPage.rawValue)
        #expect(message.entrypoint == InputEntrypoint.automation.rawValue)
        #expect(message.presentationSource == InputPresentationSource.hostFeedback.rawValue)
        #expect(message.coalescedCount == 3 && message.causedFrameUpdate && message.variableRefresh)
        #expect(message.generatedNanos == 10_000_000)
        #expect(message.dispatchStartMicros == 250)
        #expect(message.presentedMicros == 8_000)
        #expect(message.arrivedMainMicros == -1 && message.echoSentMicros == -1)
        #expect(message.traceArg1 == 8_000)
        #expect(message.traceArg0 >> 32 == 0b11)
        InputLatencyTracker.signpost(slot, to: Signposter(category: .input))
    }

    /// A display link that never ticks by itself: the rig fires the scheduler's frames.
    @MainActor
    final class RigLink: FrameLink {
        var isPaused = false
        func invalidate() {}
    }

    @MainActor
    final class Counter {
        var value = 0
    }

    /// A tracker on the real ``InputCommitObserver`` (in a private run-loop mode, so no other main-queue work runs
    /// in the turns it drives) and a real `PresentationClock` on a scheduler with a fake link and a fixed display.
    @MainActor
    final class AllocationRig {
        static let eventsPerTurn = 64
        static let mode = CFRunLoopMode("InputLatencyTrackerTests.allocation" as CFString)
        let scheduler: FrameScheduler
        let clock: PresentationClock
        let window: NSWindow
        let tracker: InputLatencyTracker
        let textInput: TextInputStage
        let closed: Counter
        private let keepAlive: CFRunLoopTimer
        private let timestamp: TimeInterval
        /// The key down each tracked key's text input call interprets (one event, so the loop allocates none).
        private let keyEvent: NSEvent
        private var frameTime: Double = 1000

        init() throws {
            let timestamp = TimeInterval(InputLatencyTracker.uptimeNanos()) / 1e9
            self.timestamp = timestamp
            keyEvent = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                     timestamp: timestamp, windowNumber: 0, context: nil,
                                                     characters: "a", charactersIgnoringModifiers: "a",
                                                     isARepeat: false, keyCode: 0))
            let scheduler = FrameScheduler.testing(clock: ManualClock(), mediaTime: { 1000 }) { _ in RigLink() }
            let display = PresentationDisplay(displayID: 1, minimumRefreshInterval: 1.0 / 60,
                                              maximumRefreshInterval: 1.0 / 60)
            let clock = PresentationClock(offset: PresentationOffset(nanos: 0), scheduler: { _ in scheduler },
                                          display: { _ in display })
            let closed = Counter()
            self.closed = closed
            self.scheduler = scheduler
            self.clock = clock
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 64, height: 64), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            tracker = InputLatencyTracker(
                table: InputLatencySlotTable(), ring: InputLatencyRing(), presentation: clock,
                boundary: InputCommitObserver(mode: Self.mode),
                emit: { slot in
                    InputLatencyTracker.tracePoint(InputLatencySignpostMessage(slot: slot), slot: slot)
                    closed.value += 1
                },
                batchSink: nil, now: InputLatencyTracker.uptimeNanos)
            textInput = TextInputStage(tracker: tracker)
            // The far-future timer only keeps the private mode non-empty, so a turn runs its observers.
            keepAlive = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 3_600, 0, 0, 0) { _ in }
            CFRunLoopAddTimer(CFRunLoopGetMain(), keepAlive, Self.mode)
        }

        func invalidate() {
            CFRunLoopTimerInvalidate(keepAlive)
        }

        /// One turn of typing: half the keys to a view, half to a terminal whose frame came in the same turn, then
        /// the turn's commit and the held link's next frame.
        func trackedTurn() {
            for index in 0..<Self.eventsPerTurn {
                let target: InputTarget = index.isMultiple(of: 2) ? .textView : .terminal
                guard let token = tracker.begin(kind: .keyPress, target: target, entrypoint: .person,
                                                eventTimestamp: timestamp, window: window) else { continue }
                let outer = textInput.keyDownDispatchBegan(token, timestamp: timestamp)
                textInput.interpreting(keyEvent) {}
                tracker.endDispatch(token)
                textInput.keyDownDispatchEnded(restoring: outer)
                if target == .terminal { tracker.mark(token, .contentSubmitted) }
            }
            turnAndFrame()
        }

        /// The same turn and frame with no input: the hold stays subscribed, so the frame costs the same.
        func idleTurn() {
            clock.holdForInput(on: scheduler)
            turnAndFrame()
        }

        private func turnAndFrame() {
            _ = CFRunLoopRunInMode(Self.mode, 0, false)
            frameTime += 1.0 / 60
            scheduler.frameDidFire(timestamp: frameTime, refreshInterval: 1.0 / 60,
                                   targetTimestamp: frameTime + 1.0 / 60)
        }
    }

    /// The per-event path (begin, the text input stage's two marks, the dispatch end, the turn's commit through the real observer, the real
    /// PresentationClock's resolve at the next frame, the close and the trace point) adds no allocation per event or
    /// per turn to the loop that runs it: compared with the same turns and frames with no input.
    @Test("Tracking an event allocates nothing with the real commit observer and PresentationClock")
    func perEventPathAllocatesNothing() throws {
        let rig = try AllocationRig()
        defer { rig.invalidate() }
        // Warm up: the window's hold and estimate queue, the fake link, and the lists' and queues' capacity.
        for _ in 0..<3 { rig.trackedTurn() }
        try #require(rig.closed.value == 3 * AllocationRig.eventsPerTurn,
                     "the real boundary and clock closed \(rig.closed.value) slots")

        var opened = 0
        let control = MallocProbe.allocations { opened += ContiguousArray(repeating: 1, count: 64).count }
        try #require((control ?? 0) > 0, "malloc_logger saw no allocation on this thread: the probe cannot measure here")

        let turns = 50
        let baseline = try #require(MallocProbe.allocations { for _ in 0..<turns { rig.idleTurn() } })
        let tracked = try #require(MallocProbe.allocations { for _ in 0..<turns { rig.trackedTurn() } })
        #expect(rig.closed.value == (3 + turns) * AllocationRig.eventsPerTurn)
        #expect(tracked < baseline + turns,
                "\(tracked - min(tracked, baseline)) more allocations than the same \(turns) idle turns (\(baseline))")
        #expect(opened == 64)
    }
}

/// Counts the allocations one thread makes, through libmalloc's `malloc_logger` hook (the one malloc stack logging
/// uses), as CmuxNextFeaturesTests' probe does.
private nonisolated struct MallocProbe {
    typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    /// `MALLOC_LOG_TYPE_ALLOCATE` (libmalloc stack_logging.h).
    static let allocateType: UInt32 = 2
    static let count = ManagedAtomic<Int>(0)
    static let thread = ManagedAtomic<UInt64>(0)

    /// The allocations `body` makes on this thread, or nil when the hook is missing.
    static func allocations(_ body: () -> Void) -> Int? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
        let slot = symbol.assumingMemoryBound(to: Logger?.self)
        var id: UInt64 = 0
        pthread_threadid_np(nil, &id)
        count.store(0, ordering: .relaxed)
        thread.store(id, ordering: .relaxed)
        let previous = slot.pointee
        slot.pointee = { type, _, _, _, _, _ in
            guard type & MallocProbe.allocateType != 0 else { return }
            var id: UInt64 = 0
            pthread_threadid_np(nil, &id)
            if id == MallocProbe.thread.load(ordering: .relaxed) { MallocProbe.count.wrappingIncrement(ordering: .relaxed) }
        }
        body()
        slot.pointee = previous
        thread.store(0, ordering: .relaxed)
        return count.load(ordering: .relaxed)
    }
}
