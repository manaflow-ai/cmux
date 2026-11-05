// SPDX-License-Identifier: GPL-3.0-or-later
@testable import CmuxCuaHelperCore
import Foundation
import os
import Testing

/// A clock the test moves by hand; sleeping advances it.
private final class FakeClock: Sendable {
    private let nanos = OSAllocatedUnfairLock<UInt64>(initialState: 1_000_000_000)
    let slept = OSAllocatedUnfairLock<[Duration]>(initialState: [])
    /// Person events to inject while the gate sleeps: one per sleep.
    let duringSleep = OSAllocatedUnfairLock<[@Sendable () -> Void]>(initialState: [])

    var now: UInt64 { nanos.withLock { $0 } }
    func advance(_ duration: Duration) { nanos.withLock { $0 += UInt64(duration.nanoseconds) } }

    func gate(_ rule: TakeoverRule = TakeoverRule()) -> TakeoverGate {
        TakeoverGate(rule: rule, now: { self.now }, sleep: { duration in
            self.slept.withLock { $0.append(duration) }
            self.advance(duration)
            let next = self.duringSleep.withLock { $0.isEmpty ? nil : $0.removeFirst() }
            next?()
        })
    }
}

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

    @Test func aBenchStampRoundTripsAndIsNotOurMarker() {
        let stamp = TakeoverTap.benchStamp(nanos: 5_000)
        #expect(stamp != TakeoverMarker.value)
        #expect(TakeoverTap.benchLatency(userData: stamp, nowNanos: 5_750) == 750)
        #expect(TakeoverTap.benchLatency(userData: 0, nowNanos: 5_750) == nil)
        #expect(TakeoverTap.benchLatency(userData: TakeoverMarker.value, nowNanos: 5_750) == nil)
        #expect(classifyInput(type: TapEventType.scrollWheel, userData: stamp, sourcePID: 9, ownPID: ownPID) == .person)
    }

    // MARK: The rule

    @Test func withNoDetectorTheGateIsOpenAndSaysSo() async throws {
        let clock = FakeClock()
        let gate = clock.gate()
        gate.observe(.person, at: clock.now)
        #expect(gate.holder() == .unwatched)
        try await gate.admit("click", requirement: .act)
        #expect(clock.slept.withLock { $0 }.isEmpty)
    }

    @Test func thePersonTakesOverOnDeliberateInputAndTheAgentResumesAfterQuiet() async throws {
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

    @Test func ourOwnInputNeverTakesOver() async throws {
        let clock = FakeClock()
        let gate = clock.gate()
        gate.setHealthy(true)
        for _ in 0..<1000 { gate.observe(.agent, at: clock.now) }
        #expect(gate.holder() == .agent)
        #expect(gate.snapshot().takeovers == 0)
        #expect(gate.snapshot().agentEvents == 1000)
        try await gate.admit("type_text", requirement: .act)
    }

    @Test func anActingCallWaitsForTheQuietThenRuns() async throws {
        let clock = FakeClock()
        let gate = clock.gate()
        gate.setHealthy(true)
        gate.observe(.person, at: clock.now)
        clock.advance(.milliseconds(500))
        try await gate.admit("click", requirement: .act)
        #expect(clock.slept.withLock { $0 } == [.milliseconds(1000)])
        #expect(gate.snapshot().held == 1)
    }

    @Test func observingNeverWaits() async throws {
        let clock = FakeClock()
        let gate = clock.gate()
        gate.setHealthy(true)
        gate.observe(.person, at: clock.now)
        try await gate.admit("get_window_state", requirement: .observe)
        #expect(clock.slept.withLock { $0 }.isEmpty)
    }

    @Test func aPersonWhoKeepsGoingGetsTheCallRefusedAtTheHold() async throws {
        let clock = FakeClock()
        let gate = clock.gate(TakeoverRule(quiet: .milliseconds(1500), hold: .seconds(3)))
        gate.setHealthy(true)
        gate.observe(.person, at: clock.now)
        // The person types again during each wait.
        clock.duringSleep.withLock { $0 = Array(repeating: { gate.observe(.person, at: clock.now) }, count: 10) }
        await #expect(throws: TakeoverRefusal(tool: "click")) {
            try await gate.admit("click", requirement: .act)
        }
        #expect(gate.snapshot().refused == 1)
        // It never slept past the hold.
        let total = clock.slept.withLock { $0 }.reduce(Duration.zero, +)
        #expect(total <= .seconds(3))
    }

    @Test func theRefusalNamesItsCodeAndTool() {
        let refusal = TakeoverRefusal(tool: "click")
        #expect(refusal.description.hasPrefix("person_in_control:"))
        #expect(refusal.description.contains("`click` did not run"))
    }

    @Test func losingTheDetectorReopensTheGate() async throws {
        let clock = FakeClock()
        let gate = clock.gate()
        gate.setHealthy(true)
        gate.observe(.person, at: clock.now)
        gate.setHealthy(false)
        #expect(gate.holder() == .unwatched)
        try await gate.admit("click", requirement: .act)
    }

    @Test func anActingCallRestartsTheDetector() async throws {
        let started = OSAllocatedUnfairLock(initialState: 0)
        let gate = TakeoverGate(starter: { started.withLock { $0 += 1 } })
        try await gate.admit("get_window_state", requirement: .observe)
        try await gate.admit("click", requirement: .act)
        #expect(started.withLock { $0 } == 1)
    }

    @Test func anUntrustedHelperNeverStartsTheTap() {
        let tap = TakeoverTap(trusted: { false })
        tap.ensureStarted()
        #expect(tap.gate.holder() == .unwatched)
    }
}
