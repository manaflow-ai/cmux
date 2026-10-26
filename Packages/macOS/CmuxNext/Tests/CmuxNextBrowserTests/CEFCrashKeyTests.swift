@testable import CmuxNextBrowser
import CmuxNextWakeups
import Foundation
import Testing

/// The Chromium runtime names its state in the crash keys (p10-stability-207, ``CrashKeySlots/Key/cefState``):
/// each state change, and `in_pump` while a message pump pass runs.
@MainActor
@Suite(.serialized) struct CEFCrashKeyTests {
    @Test func eachStateChangeIsNamed() {
        let keys = CrashKeySlots()
        let runtime = CEFRuntime(storage: CEFProfileStorage(root: Self.root()))
        runtime.attachCrashKeys(keys)
        #expect(keys.value(.cefState) == 0, "Chromium never started")
        runtime.state = .loading
        #expect(keys.value(.cefState) == CrashKeySlots.CEFState.initializing.rawValue)
        runtime.state = .ready
        #expect(keys.value(.cefState) == CrashKeySlots.CEFState.running.rawValue)
        runtime.noteCrashKeyShuttingDown()
        #expect(keys.value(.cefState) == CrashKeySlots.CEFState.shuttingDown.rawValue)
        runtime.state = .shutDown
        #expect(keys.value(.cefState) == CrashKeySlots.CEFState.shutDown.rawValue)
        runtime.state = .failed("no framework")
        #expect(keys.value(.cefState) == CrashKeySlots.CEFState.failed.rawValue)
    }

    @Test func aPumpPassIsNamedWhileItRuns() throws {
        let keys = CrashKeySlots()
        let runtime = CEFRuntime(shim: try PumpSpy.library(), storage: CEFProfileStorage(root: Self.root()))
        runtime.attachCrashKeys(keys)
        #expect(keys.value(.cefState) == CrashKeySlots.CEFState.running.rawValue)
        PumpSpy.keysAddress = keys.wordsAddress
        PumpSpy.seen = 0
        runtime.pumpWork()
        #expect(PumpSpy.seen == CrashKeySlots.CEFState.inPump.rawValue, "CefDoMessageLoopWork ran unnamed")
        #expect(keys.value(.cefState) == CrashKeySlots.CEFState.running.rawValue, "the state before the pass is back")
    }

    private static func root() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "cef-crash-keys-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}

/// A shim whose `cmux_shim_do_work` reads the crash keys' Chromium state (a C function captures nothing).
private nonisolated enum PumpSpy {
    nonisolated(unsafe) static var keysAddress: UInt = 0
    nonisolated(unsafe) static var seen: UInt64 = 0

    static func library() throws -> CEFShimLibrary {
        let doWork: @convention(c) () -> Void = {
            PumpSpy.seen = CrashKeySlots.word(CrashKeySlots.Key.cefState.rawValue, at: PumpSpy.keysAddress)
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            name == "cmux_shim_do_work" ? unsafeBitCast(doWork, to: UnsafeMutableRawPointer.self)
                : unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}
