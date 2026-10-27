#if DEBUG
import AppKit
@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextSettings
import Testing

/// The time `debug.key`'s key-down carries (``DebugKey/keyDown(_:at:windowNumber:)``): the client's
/// send time when the request has `timestamp` (bench-typing.py sends it, so the typing probe counts
/// the control socket's utility lane and the main-thread wait), else the main thread's injection time.
@MainActor @Suite struct DebugKeyInjectionTimeTests {
    @Test func theKeyCarriesTheClientsSendTimeWhenItSentOne() throws {
        let time = InjectedKeyTime(params: ["key": "a", "timestamp": 100.25], injectedAt: 100.75)
        let event = try #require(DebugKey.keyDown(DebugKey.keyPress("a", modifiers: []), at: time, windowNumber: 0))
        #expect(event.timestamp == 100.25)
        #expect(time.report["injected_at"] == .number(100.75))
        let wait = try #require(time.report["client_to_injection_ms"]?.doubleValue)
        #expect(abs(wait - 500) < 1e-6, "the reply names the wait before injection apart from the key's own time")
    }

    @Test func withoutAClientTimeTheKeyCarriesTheInjectionTime() throws {
        let time = InjectedKeyTime(params: ["key": "a"], injectedAt: 42.5)
        let event = try #require(DebugKey.keyDown(DebugKey.keyPress("a", modifiers: []), at: time, windowNumber: 0))
        #expect(event.timestamp == 42.5)
        #expect(time.report["client_to_injection_ms"] == .null)
    }
}
#endif
