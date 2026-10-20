import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Foundation
import Testing

/// Sleepy Mode (`palette.sleepyMode`, classic #6740): a full-screen keep-awake screensaver. Running
/// the action covers every screen with the sleepy scene and keeps the Mac and its display awake;
/// running it again, or any key or click on the scene, wakes it and lets the Mac sleep again.
@MainActor @Suite(.serialized)
struct SleepyModeTests {
    static func services() -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        return services
    }

    static var overlayWindows: [NSWindow] {
        NSApp.windows.filter { $0.identifier?.rawValue == "cmux.next.sleepyMode" && $0.isVisible }
    }

    /// The palette row, the Window menu item, `cmux app sleepy-mode` and MCP `action run` all run
    /// this one action: it is available and toggles the screensaver on every screen.
    @Test func theActionIsAvailableAndTogglesTheScreensaver() {
        let services = Self.services()
        #expect(services.registry.unavailableReason(for: "palette.sleepyMode") == nil)
        #expect(services.registry.perform("palette.sleepyMode"), "the first run turns Sleepy Mode on")
        if !NSScreen.screens.isEmpty {
            #expect(Self.overlayWindows.count == NSScreen.screens.count, "one scene window per screen")
            #expect(Self.overlayWindows.allSatisfy { $0.level == .screenSaver })
        }
        #expect(services.registry.perform("palette.sleepyMode"), "the second run wakes it")
        #expect(Self.overlayWindows.isEmpty)
    }
}
