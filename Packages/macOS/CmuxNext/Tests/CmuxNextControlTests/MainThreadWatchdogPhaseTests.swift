@testable import CmuxNextControl
import CmuxNextCompat
import CmuxNextSettings
import CmuxNextTrace
import CmuxNextWakeups
import CoreFoundation
import Foundation
import Testing

/// The main thread's phase in the watchdog's records (p10-stability-031): the CEF message pump runs on the
/// main thread and sets the crash keys' CEF state to `inPump` for each pass; the watchdog reads it while the
/// main thread is suspended for its sample, and both the stall record and the hang its sink gets say `cef_pump`.
@Suite(.serialized, .timeLimit(.minutes(1))) struct MainThreadWatchdogPhaseTests {
    #if DEBUG
    /// The watchdog reads an injected clock that moves only inside the stall, and the stall ends only once
    /// the hang reached the sink: host load can neither add a stall nor make the hang report miss this one.
    @MainActor
    @Test func aStallInsideTheCEFPumpNamesItsPhaseInTheStallRecordAndTheHang() throws {
        let clock = ManualUptime()
        let keys = CrashKeySlots()
        let seen = PhaseSeen()
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), logStalls: false,
                                                               hangThreshold: .milliseconds(100), hangAssertThreshold: nil),
                                          uptime: clock.read)
        watchdog.attach(hangWatch: HangWatch(), crashKeys: keys)
        watchdog.onHang = { hang in seen.hang(hang.phase) }
        watchdog.onStall = { record in seen.stall(record.details["phase"]?.stringValue) }
        watchdog.start()
        defer { watchdog.stop() }
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            stallInsideTheCEFPump(keys: keys, clock: clock, seen: seen)
            CFRunLoopStop(CFRunLoopGetMain())
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        CFRunLoopRunInMode(.defaultMode, 30, false)
        #expect(seen.hangPhases == ["cef_pump"], "the hang the sink got")
        #expect(seen.stallPhases.contains("cef_pump"), "the stall record: \(seen.stallPhases)")
        #expect(keys.value(.cefState) == 0, "the pass put the state back")
    }
    #endif

    @Test func onlyThePumpStateIsTheCEFPumpPhase() {
        #expect(MainThreadWatchdog.phaseLabel(cefState: CrashKeySlots.CEFState.inPump.rawValue) == "cef_pump")
        #expect(MainThreadWatchdog.phaseLabel(cefState: CrashKeySlots.CEFState.running.rawValue) == nil)
        #expect(MainThreadWatchdog.phaseLabel(cefState: 0) == nil)
    }
}

/// A CEF pump pass that stalls: the CEF state at `inPump`, the clock past the hang threshold, and the main
/// thread held until the hang reached the sink (a 20 s wall-clock bound turns a missing report into a test
/// failure, not a hang).
@inline(never)
private func stallInsideTheCEFPump(keys: CrashKeySlots, clock: ManualUptime, seen: PhaseSeen) {
    keys.set(.cefState, CrashKeySlots.CEFState.inPump.rawValue)
    clock.advance(by: .seconds(3))
    let deadline = ContinuousClock.now + .seconds(20)
    while seen.hangPhases.isEmpty, ContinuousClock.now < deadline {}
    keys.set(.cefState, 0)
}

/// The phases the watchdog's hang and stall sinks received (nil: no phase).
private final class PhaseSeen: Sendable {
    private let hangs = Mutex<[String?]>([]), stalls = Mutex<[String?]>([])
    var hangPhases: [String?] { hangs.withLock { $0 } }
    var stallPhases: [String?] { stalls.withLock { $0 } }
    func hang(_ phase: String?) { hangs.withLock { $0.append(phase) } }
    func stall(_ phase: String?) { stalls.withLock { $0.append(phase) } }
}
