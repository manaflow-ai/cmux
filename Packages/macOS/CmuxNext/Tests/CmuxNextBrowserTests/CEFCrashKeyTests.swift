@testable import CmuxNextBrowser
import CmuxNextWakeups
import Foundation
import Testing

/// The Chromium runtime names its state in the crash keys (``CrashKeySlots/Key/cefState``):
/// each state change (`in_pump` while a pass runs is the pump's: `CEFMessagePumpCrashKeyTests`).
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

    private static func root() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "cef-crash-keys-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}
