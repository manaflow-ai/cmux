// SPDX-License-Identifier: GPL-3.0-or-later
@testable import CmuxRemoteComputerUse
import Foundation
import os
import Testing

/// A clock the test moves by hand; a wait advances it.
private final class FakeClock: Sendable {
    private let nanos = OSAllocatedUnfairLock<UInt64>(initialState: 1_000_000_000)
    let slept = OSAllocatedUnfairLock<[Duration]>(initialState: [])
    /// Person events to inject while the gate waits: one per wait.
    let duringSleep = OSAllocatedUnfairLock<[@Sendable () -> Void]>(initialState: [])

    var now: UInt64 { nanos.withLock { $0 } }
    func advance(_ duration: Duration) { nanos.withLock { $0 += UInt64(duration.totalNanos) } }

    func gate(_ rule: TakeoverRule = TakeoverRule(), starter: (@Sendable () -> Void)? = nil) -> TakeoverGate {
        TakeoverGate(rule: rule, now: { self.now }, sleep: { duration in
            self.slept.withLock { $0.append(duration) }
            self.advance(duration)
            let next = self.duringSleep.withLock { $0.isEmpty ? nil : $0.removeFirst() }
            next?()
        }, starter: starter)
    }
}

/// The takeover detector as the engine's `wait_idle` (#36080, #36377, #36431): who made each
/// input event, when the person holds the Mac, and how long an acting call waits.
@Suite struct TakeoverTests {
    private let ownPID: Int64 = 4242

    // MARK: Provenance

    @Test func ourMarkerOrOurPidIsTheAgentWhateverTheType() {
        for type in [TapEventType.keyDown, TapEventType.leftMouseDown, TapEventType.mouseMoved, TapEventType.scrollWheel] {
            #expect(classifyInput(type: type, userData: TakeoverMarker.value, sourcePID: 0, ownPID: ownPID) == .agent)
            #expect(classifyInput(type: type, userData: 0, sourcePID: ownPID, ownPID: ownPID) == .agent)
        }
    }

    @Test func anyoneElsesDeliberateInputIsThePerson() {
        let deliberate = [TapEventType.keyDown, TapEventType.leftMouseDown, TapEventType.rightMouseDown,
                          TapEventType.otherMouseDown, TapEventType.scrollWheel, TapEventType.leftMouseDragged]
        for type in deliberate {
            // Hardware (pid 0), another process, and a near-miss marker all count as the person.
            #expect(classifyInput(type: type, userData: 0, sourcePID: 0, ownPID: ownPID) == .person)
            #expect(classifyInput(type: type, userData: 0, sourcePID: 77, ownPID: ownPID) == .person)
            #expect(classifyInput(type: type, userData: TakeoverMarker.value ^ 1, sourcePID: 0, ownPID: ownPID) == .person)
        }
    }

    @Test func pointerMovementIsNotATakeover() {
        #expect(classifyInput(type: TapEventType.mouseMoved, userData: 0, sourcePID: 0, ownPID: ownPID) == .personPointer)
        #expect(classifyInput(type: TapEventType.flagsChanged, userData: 0, sourcePID: 0, ownPID: ownPID) == .ignored)
    }

    @Test func pidZeroIsNeverOurs() {
        // A process whose pid we failed to read must not turn hardware input into ours.
        #expect(classifyInput(type: TapEventType.keyDown, userData: 0, sourcePID: 0, ownPID: 0) == .person)
    }

    @Test func theMarkerIsTheBytesCMUXSYNT() {
        #expect(withUnsafeBytes(of: TakeoverMarker.value.bigEndian) { Array($0) } == Array("CMUXSYNT".utf8))
        #expect(TakeoverMarker.userDataField == 42)
        #expect(TakeoverMarker.sourcePIDField == 41)
    }

    @Test func theMaskCoversEveryClassifiedType() {
        for type in TapEventType.deliberate.union(TapEventType.pointer) {
            #expect(TapEventType.mask & (1 << UInt64(type)) != 0)
        }
    }

    @Test func withoutInputMonitoringTheTapNeverListensToKeys() {
        // A listen-only tap on keys is what asks for Input Monitoring; the rest asks for nothing.
        #expect(TapEventType.pointerOnlyMask & (1 << UInt64(TapEventType.keyDown)) == 0)
        for type in [TapEventType.leftMouseDown, TapEventType.scrollWheel, TapEventType.mouseMoved, TapEventType.leftMouseDragged] {
            #expect(TapEventType.pointerOnlyMask & (1 << UInt64(type)) != 0)
        }
    }

    // MARK: wait_idle

    @Test func withNoDetectorThePersonCountsAsIdle() {
        let clock = FakeClock()
        let gate = clock.gate()
        gate.observe(.person, at: clock.now)
        #expect(gate.holder() == .unwatched)
        #expect(gate.waitIdle(limit: .seconds(10)))
        #expect(clock.slept.withLock { $0 }.isEmpty)
    }

    @Test func thePersonTakesOverOnDeliberateInputAndTheAgentResumesAfterQuiet() {
        let clock = FakeClock()
        let gate = clock.gate()
        gate.setHealthy(true)
        #expect(gate.holder() == .agent)
        gate.observe(.personPointer, x: 10, y: 20, at: clock.now)
        #expect(gate.holder() == .agent)
        gate.observe(.person, x: 11, y: 21, at: clock.now)
        #expect(gate.holder() == .person(resumesAt: clock.now + 1_500_000_000))
        clock.advance(.milliseconds(1499))
        #expect(gate.holder() != .agent)
        clock.advance(.milliseconds(1))
        #expect(gate.holder() == .agent)
        #expect(gate.snapshot().takeovers == 1)
        #expect(gate.personPointer() == PointerSample(x: 11, y: 21, atNanos: 1_000_000_000))
    }

    /// The focus guard's reading (`person_events`): the person's deliberate inputs only, and
    /// nothing while the detector cannot tell theirs from ours.
    @Test func thePersonEventCountIsTheirsAloneAndOnlyWhileWatched() {
        let clock = FakeClock()
        let gate = clock.gate()
        gate.observe(.person, at: clock.now)
        #expect(gate.personEventCount() == nil, "unwatched: no count, so the guard never trusts it")
        gate.setHealthy(true)
        let start = gate.personEventCount()
        #expect(start != nil)
        gate.observe(.agent, at: clock.now)
        gate.observe(.personPointer, x: 1, y: 2, at: clock.now)
        #expect(gate.personEventCount() == start, "our input and a resting hand are not the person moving focus")
        gate.observe(.person, at: clock.now)
        #expect(gate.personEventCount() == start.map { $0 + 1 })
        gate.setHealthy(false)
        #expect(gate.personEventCount() == nil)
    }

    @Test func ourOwnInputNeverTakesOver() {
        let clock = FakeClock()
        let gate = clock.gate()
        gate.setHealthy(true)
        for _ in 0..<1000 { gate.observe(.agent, at: clock.now) }
        #expect(gate.holder() == .agent)
        #expect(gate.snapshot().takeovers == 0)
        #expect(gate.snapshot().agentEvents == 1000)
        #expect(gate.waitIdle(limit: .seconds(10)))
    }

    @Test func anActingCallWaitsForTheQuietThenRuns() {
        let clock = FakeClock()
        let gate = clock.gate()
        gate.setHealthy(true)
        gate.observe(.person, at: clock.now)
        clock.advance(.milliseconds(500))
        #expect(gate.waitIdle(limit: .seconds(10)))
        #expect(clock.slept.withLock { $0 } == [.milliseconds(1000)])
        #expect(gate.snapshot().held == 1)
    }

    @Test func aPersonWhoKeepsGoingRunsOutTheLimit() {
        let clock = FakeClock()
        let gate = clock.gate()
        gate.setHealthy(true)
        gate.observe(.person, at: clock.now)
        // The person types again during each wait.
        clock.duringSleep.withLock { $0 = Array(repeating: { gate.observe(.person, at: clock.now) }, count: 10) }
        #expect(!gate.waitIdle(limit: .seconds(3)))
        #expect(gate.snapshot().refused == 1)
        // It never waited past the limit.
        let total = clock.slept.withLock { $0 }.reduce(Duration.zero, +)
        #expect(total <= .seconds(3))
    }

    @Test func aZeroLimitNeverWaits() {
        let clock = FakeClock()
        let gate = clock.gate()
        gate.setHealthy(true)
        gate.observe(.person, at: clock.now)
        #expect(!gate.waitIdle(limit: .zero))
        #expect(clock.slept.withLock { $0 }.isEmpty)
    }

    @Test func losingTheDetectorReopensTheGate() {
        let clock = FakeClock()
        let gate = clock.gate()
        gate.setHealthy(true)
        gate.observe(.person, at: clock.now)
        gate.setHealthy(false)
        #expect(gate.holder() == .unwatched)
        #expect(gate.waitIdle(limit: .seconds(1)))
    }

    @Test func eachWaitRestartsTheDetector() {
        let started = OSAllocatedUnfairLock(initialState: 0)
        let gate = FakeClock().gate(starter: { started.withLock { $0 += 1 } })
        _ = gate.waitIdle(limit: .seconds(1))
        _ = gate.waitIdle(limit: .seconds(1))
        #expect(started.withLock { $0 } == 2)
    }

    @Test func anUntrustedWorkerNeverStartsTheTap() {
        let tap = TakeoverTap(trusted: { false })
        tap.ensureStarted()
        #expect(tap.gate.holder() == .unwatched)
    }
}
