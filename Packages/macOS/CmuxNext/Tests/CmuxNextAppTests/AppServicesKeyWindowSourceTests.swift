import AppKit
import Testing
@testable import CmuxNextApp

/// AppServices never reads the global `NSApp` for the key window: `NSApp` is `NSApplication!`, nil in
/// a test process that never made `NSApplication.shared`, and its implicit unwrap ended the whole
/// test process (and hid every later test) as soon as a test reached a key-window lookup.
///
/// The fleet runs a suite alone in its own process (`swift test --filter`), where nothing makes the
/// application object, so a lookup that still reads `NSApp` traps here.
@MainActor
@Suite(.serialized)
struct AppServicesKeyWindowSourceTests {
    /// The lookups the quit's sheet (`QuitCoordinator.sheetWindow`), the action handlers
    /// (`windows.active`) and the key routing (`keyWindowRole`) make.
    @Test func keyWindowLookupsWithNoApplicationObjectDoNotTrap() {
        let services = AppServices(environment: AppEnvironment.current([:]))
        #expect(services.keyWindowSource() == nil)
        #expect(services.windows.active == nil)
        #expect(services.keyWindowRole == nil)
    }

    /// The same check when an earlier test in this process already made `NSApplication.shared` (then
    /// `NSApp` is set and the trap cannot show): every lookup asks the source the composition root
    /// passed, never the global application.
    @Test func everyKeyWindowLookupAsksTheInjectedSource() {
        let asks = KeyWindowAsks()
        let services = AppServices(environment: AppEnvironment.current([:]), keyWindowSource: { asks.count += 1; return nil })
        let windows = services.windows
        var before = asks.count
        #expect(windows.active == nil)
        #expect(asks.count == before + 1, "windows.active did not ask the injected key-window source")
        before = asks.count
        #expect(services.keyWindowRole == nil)
        #expect(asks.count == before + 1, "keyWindowRole did not ask the injected key-window source")
    }
}

/// How many times a key-window source was asked.
@MainActor
private final class KeyWindowAsks {
    var count = 0
}
