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
    func advance(_ duration: Duration) { nanos.withLock { $0 += UInt64(duration.totalNanos) } }

    func gate(_ rule: TakeoverRule = TakeoverRule(), focus: TakeoverGate.FocusProvider? = nil) -> TakeoverGate {
        TakeoverGate(rule: rule, now: { self.now }, sleep: { duration in
            self.slept.withLock { $0.append(duration) }
            self.advance(duration)
            let next = self.duringSleep.withLock { $0.isEmpty ? nil : $0.removeFirst() }
            next?()
        }, focus: focus)
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

    @Test func withoutInputMonitoringTheTapNeverListensToKeys() {
        // A listen-only tap on keys is what asks for Input Monitoring; the rest asks for nothing.
        #expect(TapEventType.pointerOnlyMask & (1 << UInt64(TapEventType.keyDown)) == 0)
        for type in [TapEventType.leftMouseDown, TapEventType.scrollWheel, TapEventType.mouseMoved, TapEventType.leftMouseDragged] {
            #expect(TapEventType.pointerOnlyMask & (1 << UInt64(type)) != 0)
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

    // MARK: Working at the same time

    private func footprint(_ json: String, tool: String = "click",
                           owner: @escaping (UInt32) -> Int32? = { _ in nil }) -> ActingFootprint {
        ActingFootprint(tool: tool, arguments: Data(json.utf8), owner: owner)
    }

    @Test func aBackgroundCallToOneAppTouchesOnlyThatApp() {
        #expect(footprint(#"{"pid":200,"window_id":31,"x":5,"y":6}"#)
            == ActingFootprint(pids: [200], windowIDs: [31], shared: false))
        #expect(footprint(#"{"pid":200,"delivery_mode":"background","element_token":"e1"}"#)
            == ActingFootprint(pids: [200], shared: false))
        #expect(footprint(#"{"target":{"kind":"window","pid":200,"window_id":31}}"#)
            == ActingFootprint(pids: [200], windowIDs: [31], shared: false))
    }

    @Test func theSharedCursorOrNoAppCollidesEverywhere() {
        // The fallback routes drive what the person is using.
        #expect(footprint(#"{"pid":200,"window_id":31,"delivery_mode":"foreground"}"#).shared)
        #expect(footprint(#"{"pid":200,"scope":"desktop","x":5,"y":6}"#).shared)
        #expect(footprint(#"{"target":{"kind":"desktop","display_id":"primary"},"pid":200}"#).shared)
        // No app named (launch_app by name, a call we cannot read): assume the worst.
        #expect(footprint(#"{"name":"Notes"}"#).shared)
        #expect(footprint("not json").shared)
        #expect(footprint(#"{"window_id":31}"#).shared)
    }

    @Test func aToolThatTakesFocusCollidesEvenWithAnotherAppsPid() {
        // bring_to_front on another app would send the person's next keys there.
        for tool in ["bring_to_front", "launch_app", "invoke_menu", "clipboard_write"] {
            #expect(footprint(#"{"pid":200}"#, tool: tool).shared, "\(tool)")
        }
        #expect(footprint(#"{"pid":200,"steps":[{"tool":"bring_to_front","pid":300}]}"#, tool: "run_steps").shared)
        #expect(footprint(#"{"pid":200,"actions":[{"invoke_menu":{"pid":300}}]}"#, tool: "run_actions").shared)
        #expect(!footprint(#"{"pid":200,"steps":[{"tool":"set_value","pid":300}]}"#, tool: "run_steps").shared)
    }

    @Test func aWindowWithoutItsPidTakesItsOwner() {
        #expect(footprint(#"{"window_id":31}"#, owner: { $0 == 31 ? 200 : nil })
            == ActingFootprint(pids: [200], windowIDs: [31], shared: false))
    }

    @Test func aBatchTouchesEveryStepsApp() {
        let batch = footprint(#"{"pid":200,"steps":[{"tool":"click","x":1,"y":2},{"tool":"type_text","pid":300,"text":"a"}]}"#)
        #expect(batch == ActingFootprint(pids: [200, 300], shared: false))
        let fallback = footprint(#"{"pid":200,"steps":[{"tool":"click","delivery_mode":"foreground","window_id":4}]}"#)
        #expect(fallback.shared)
    }

    @Test func collisionIsTheSameAppTheSameWindowOrTheSharedCursor() {
        let person = PersonFocus(pids: [100, 101], windowIDs: [7])
        #expect(!person.collides(with: ActingFootprint(pids: [200], windowIDs: [31])))
        #expect(person.collides(with: ActingFootprint(pids: [101])))
        #expect(person.collides(with: ActingFootprint(pids: [200], windowIDs: [7])))
        #expect(person.collides(with: ActingFootprint(pids: [200], shared: true)))
    }

    @Test func theAgentWorksOnAnotherAppWhileThePersonDrives() async throws {
        let clock = FakeClock()
        let gate = clock.gate(focus: { _ in PersonFocus(pids: [100], windowIDs: [7]) })
        gate.setHealthy(true)
        gate.observe(.person, at: clock.now)
        try await gate.admit("click", requirement: .act, footprint: ActingFootprint(pids: [200], windowIDs: [31]))
        #expect(clock.slept.withLock { $0 }.isEmpty)
        #expect(gate.snapshot().alongside == 1)
        #expect(gate.snapshot().held == 0)
    }

    @Test func theAgentWaitsOnThePersonsAppOrTheSharedCursor() async throws {
        for call in [ActingFootprint(pids: [100]), ActingFootprint(pids: [200], windowIDs: [7]),
                     ActingFootprint(pids: [200], shared: true)] {
            let clock = FakeClock()
            let gate = clock.gate(focus: { _ in PersonFocus(pids: [100], windowIDs: [7]) })
            gate.setHealthy(true)
            gate.observe(.person, at: clock.now)
            try await gate.admit("click", requirement: .act, footprint: call)
            #expect(clock.slept.withLock { $0 } == [.milliseconds(1500)])
            #expect(gate.snapshot().held == 1)
            #expect(gate.snapshot().alongside == 0)
        }
    }

    @Test func anUnreadableFocusOrNoProbeCollides() async throws {
        let providers: [TakeoverGate.FocusProvider?] = [nil, { _ in nil }]
        for focus in providers {
            let clock = FakeClock()
            let gate = clock.gate(focus: focus)
            gate.setHealthy(true)
            gate.observe(.person, at: clock.now)
            try await gate.admit("click", requirement: .act, footprint: ActingFootprint(pids: [200]))
            #expect(gate.snapshot().held == 1)
        }
    }

    @Test func aWaitingCallRunsOnceThePersonMovesToAnotherApp() async throws {
        let clock = FakeClock()
        let front = OSAllocatedUnfairLock<Int32>(initialState: 200)
        let gate = clock.gate(TakeoverRule(quiet: .milliseconds(1500), hold: .seconds(3)),
                              focus: { _ in PersonFocus(pids: [front.withLock { $0 }]) })
        gate.setHealthy(true)
        gate.observe(.person, at: clock.now)
        // During the wait the person clicks into another app and keeps going.
        clock.duringSleep.withLock { $0 = [{ front.withLock { $0 = 100 }; gate.observe(.person, at: clock.now) }] }
        try await gate.admit("click", requirement: .act, footprint: ActingFootprint(pids: [200]))
        #expect(clock.slept.withLock { $0 } == [.milliseconds(1500)])
        #expect(gate.snapshot().alongside == 1)
        #expect(gate.snapshot().refused == 0)
    }

    @Test func thePersonsFocusIsAskedWithTheirPointer() async throws {
        let clock = FakeClock()
        let seen = OSAllocatedUnfairLock<PointerSample?>(initialState: nil)
        let gate = clock.gate(focus: { pointer in
            seen.withLock { $0 = pointer }
            return PersonFocus(pids: [100])
        })
        gate.setHealthy(true)
        gate.observe(.person, x: 40, y: 50, at: clock.now)
        try await gate.admit("scroll", requirement: .act, footprint: ActingFootprint(pids: [200]))
        #expect(seen.withLock { $0 } == PointerSample(x: 40, y: 50, atNanos: clock.now))
    }

    @Test func anUntrustedHelperNeverStartsTheTap() {
        let tap = TakeoverTap(trusted: { false })
        tap.ensureStarted()
        #expect(tap.gate.holder() == .unwatched)
    }
}
