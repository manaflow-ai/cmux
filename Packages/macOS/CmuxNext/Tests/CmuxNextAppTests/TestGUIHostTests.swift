import AppKit
import CmuxNextTestGUI
import CmuxNextTestGUIHost
import CmuxNextWakeups
import class CmuxSafeConcurrency.OnceContinuation
import func CmuxSafeConcurrency.withOnceThrowingContinuation
import Foundation
import Testing

/// The test process runs as an app. CmuxNextTestGUIHost, started when the test bundle loads, dispatches NSApp's
/// events in every run; in a run that asks for a GUI (`CMUX_CI_CONSOLE_SESSION=1`, set by the fleet worker on every
/// gui-session-v1 step, or `CMUX_TEST_REQUIRE_GUI=1`) it also finishes launching as a regular app, and never
/// activates. `.guiApp` activates per test. Before both, under `swift test` NSApp never dispatched its events, so no
/// window became key and the process never became active (fleet probe 0ba1d205).
@MainActor @Suite(.serialized)
struct TestGUIHostTests {
    nonisolated static var asksForGUI: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["CMUX_CI_CONSOLE_SESSION"] == "1" || environment["CMUX_TEST_REQUIRE_GUI"] == "1"
    }

    /// No trait skip: the lane fails a suite on any skipped test when `CMUX_TEST_REQUIRE_GUI=1`.
    @Test func theHostDispatchesEventsInEveryRunAndLaunchesOnlyWhenTheRunAsksForAGUI() async {
        for _ in 0..<200 where cmux_next_test_gui_host_running() == 0 { await Task.yield() }
        #expect(cmux_next_test_gui_host_running() == 1, "the GUI test host never started")
        #expect((cmux_next_test_gui_host_launched() == 1) == Self.asksForGUI,
                "the host finished launching \(cmux_next_test_gui_host_launched() == 1) with a GUI opt-in \(Self.asksForGUI)")
    }
}

/// `.guiApp`: each test runs as the active app, and a window it orders front becomes key.
@MainActor @Suite(.serialized, .guiApp)
struct GUIAppTraitTests {
    @Test func aTestRunsAsTheActiveAppAndItsWindowBecomesKey() async throws {
        #expect(NSApp.isActive, "the test process is not the active app inside .guiApp")
        let window = NSWindow(contentRect: CGRect(x: 300, y: 300, width: 320, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        // Event-driven: AppKit's didBecomeKey notice; the Deadline only stops a window that never becomes key from
        // hanging the run.
        let key = KeyWait(window)
        window.makeKeyAndOrderFront(nil)
        let became = (try? await Deadline(.seconds(10)).run("gui-app-trait.key") { await key.value() }) ?? false
        key.stop()
        #expect(became && window.isKeyWindow, "a window the test ordered front never became key")
    }
}

/// Waits for a window's `didBecomeKeyNotification`; true at once when it is already key, false when cancelled.
@MainActor
private final class KeyWait {
    private let window: NSWindow
    private var token: NSObjectProtocol?
    private var waiting: OnceContinuation<Bool, any Error>?

    init(_ window: NSWindow) {
        self.window = window
        token = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window,
                                                       queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(true) }
        }
    }

    /// A cancellable once-continuation: the caller's Deadline cancels the wait, which then answers false.
    func value() async -> Bool {
        (try? await withOnceThrowingContinuation(cancellation: .cancellable) { (continuation: OnceContinuation<Bool, any Error>) in
            waiting = continuation
            if window.isKeyWindow { finish(true) }
        }) ?? false
    }

    private func finish(_ value: Bool) {
        guard let waiting else { return }
        self.waiting = nil
        _ = waiting.resume(returning: value)
    }

    func stop() {
        finish(false)
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
    }
}
