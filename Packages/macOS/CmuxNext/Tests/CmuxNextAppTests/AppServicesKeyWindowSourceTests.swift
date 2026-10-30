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
}
