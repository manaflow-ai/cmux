@testable import CmuxNextControl
import CmuxNextCompat
import CmuxNextSettings
import CmuxNextTrace
import CmuxNextWakeups
import CoreFoundation
import Foundation
import Testing

/// The main thread's phase in the watchdog's records: the CEF message
/// pump runs on the main thread and sets the crash keys' CEF state to `inPump` and the trace runtime's
/// `in_cef_pump` key for each pass; the watchdog reads them while the main thread is suspended for its sample,
/// and both the stall record and the hang its sink gets carry `cef=true` and say `cef_pump` (the Sentry tag
/// `hang.cef`).
@Suite(.serialized, .timeLimit(.minutes(1))) struct MainThreadWatchdogPhaseTests {
    #if DEBUG
    /// The watchdog reads an injected clock that moves only inside the stall, and the stall ends only once
    /// the hang reached the sink: host load can neither add a stall nor make the hang report miss this one.
    @MainActor
    @Test func aStallInsideTheCEFPumpIsTaggedCEFInTheStallRecordAndTheHang() throws {
        let keys = CrashKeySlots()
        let seen = watchStall(crashKeys: keys, trace: TraceRuntime(role: .app)) { inPump in
            keys.set(.cefState, inPump ? CrashKeySlots.CEFState.inPump.rawValue : 0)
        }
        #expect(seen.hangPhases == ["cef_pump"], "the hang the sink got")
        #expect(seen.hangCEF == [true], "the hang is tagged cef")
        #expect(seen.stallPhases.contains("cef_pump"), "the stall record: \(seen.stallPhases)")
        #expect(seen.stallCEF.contains(true), "the stall record carries cef=true: \(seen.stallCEF)")
        #expect(keys.value(.cefState) == 0, "the pass put the state back")
    }

    /// The Chromium host runs the pump with no app crash keys: `in_cef_pump` alone tags the stall and the hang.
    @MainActor
    @Test func aStallWithOnlyThePumpKeyIsTaggedCEF() throws {
        let trace = TraceRuntime(role: .app) // 078 attaches its `CrashKeyPage` here once it is on the base
        // skip-owner: PL-telemetry; expiry: 2026-11-06; tracking: chrome-parity-design/followups.md 2026-10-27T08:00Z w3 leftovers
        withKnownIssue("078 crash-key page: a runtime with no page keeps no key") {
            let seen = watchStall(crashKeys: nil, trace: trace) { inPump in trace.setCrashKey(.inCEFPump, inPump ? 1 : 0) }
            #expect(seen.hangPhases == ["cef_pump"], "the hang the sink got")
            #expect(seen.hangCEF == [true], "the hang is tagged cef")
            #expect(seen.stallPhases.contains("cef_pump"), "the stall record: \(seen.stallPhases)")
            #expect(seen.stallCEF.contains(true), "the stall record carries cef=true: \(seen.stallCEF)")
        } when: {
            trace.setCrashKey(.inCEFPump, 1)
            defer { trace.setCrashKey(.inCEFPump, 0) }
            return trace.crashKey(.inCEFPump) != 1
        }
    }

    /// Runs one stall on the main thread inside the CEF pump (`enterPump(true)`, then `enterPump(false)` once
    /// the hang reached the sink) under a watchdog attached to `crashKeys` and `trace`, and returns what its
    /// hang and stall sinks got. The watchdog reads an injected clock that moves only inside the stall, and
    /// the stall ends only once the hang reached the sink: host load can neither add a stall nor make the hang
    /// report miss this one.
    @MainActor
    private func watchStall(crashKeys: CrashKeySlots?, trace: TraceRuntime, enterPump: @escaping @Sendable (Bool) -> Void) -> PhaseSeen {
        let clock = ManualUptime()
        let seen = PhaseSeen()
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), logStalls: false,
                                                               hangThreshold: .milliseconds(100), hangAssertThreshold: nil),
                                          uptime: clock.read)
        watchdog.attach(hangWatch: HangWatch(), crashKeys: crashKeys, trace: trace)
        watchdog.onHang = { hang in seen.hang(hang.phase, cef: hang.cef) }
        watchdog.onStall = { record in seen.stall(record.details["phase"]?.stringValue, cef: record.details["cef"]?.boolValue == true) }
        watchdog.start()
        defer { watchdog.stop() }
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            stallInsideTheCEFPump(enterPump: enterPump, clock: clock, seen: seen)
            CFRunLoopStop(CFRunLoopGetMain())
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        CFRunLoopRunInMode(.defaultMode, 30, false)
        return seen
    }
    #endif

    /// Either key says the pump runs: `in_cef_pump`, which the pump sets in whichever process runs it (the
    /// Chromium host has no app crash keys), or the app crash keys' CEF state at `inPump`.
    @Test func eitherThePumpKeyOrThePumpStateIsInsideTheCEFPump() {
        let inPump = CrashKeySlots.CEFState.inPump.rawValue, running = CrashKeySlots.CEFState.running.rawValue
        #expect(MainThreadWatchdog.inCEFPump(cefState: inPump, pumpKey: 0))
        #expect(MainThreadWatchdog.inCEFPump(cefState: 0, pumpKey: 1), "the pump key alone: the host process")
        #expect(MainThreadWatchdog.inCEFPump(cefState: running, pumpKey: 1))
        #expect(!MainThreadWatchdog.inCEFPump(cefState: running, pumpKey: 0))
        #expect(!MainThreadWatchdog.inCEFPump(cefState: 0, pumpKey: 0))
        #expect(MainThreadWatchdog.phaseLabel(inCEFPump: true) == "cef_pump")
        #expect(MainThreadWatchdog.phaseLabel(inCEFPump: false) == nil)
        #expect(MainThreadWatchdog.cefPumpDetails["cef"]?.boolValue == true)
    }
}

/// A CEF pump pass that stalls: the pump's key set (`enterPump(true)`), the clock past the hang threshold, and
/// the main thread held until the hang reached the sink (a 20 s wall-clock bound turns a missing report into a
/// test failure, not a hang).
@inline(never)
private func stallInsideTheCEFPump(enterPump: @Sendable (Bool) -> Void, clock: ManualUptime, seen: PhaseSeen) {
    enterPump(true)
    clock.advance(by: .seconds(3))
    let deadline = ContinuousClock.now + .seconds(20)
    while seen.hangPhases.isEmpty, ContinuousClock.now < deadline {}
    enterPump(false)
}

/// The phases (nil: no phase) and `cef` flags the watchdog's hang and stall sinks received.
private final class PhaseSeen: Sendable {
    private let hangs = Mutex<[(phase: String?, cef: Bool)]>([]), stalls = Mutex<[(phase: String?, cef: Bool)]>([])
    var hangPhases: [String?] { hangs.withLock { $0.map(\.phase) } }
    var hangCEF: [Bool] { hangs.withLock { $0.map(\.cef) } }
    var stallPhases: [String?] { stalls.withLock { $0.map(\.phase) } }
    var stallCEF: [Bool] { stalls.withLock { $0.map(\.cef) } }
    func hang(_ phase: String?, cef: Bool) { hangs.withLock { $0.append((phase, cef)) } }
    func stall(_ phase: String?, cef: Bool) { stalls.withLock { $0.append((phase, cef)) } }
}
