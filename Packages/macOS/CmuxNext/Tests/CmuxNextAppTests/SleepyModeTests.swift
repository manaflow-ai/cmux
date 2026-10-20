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

    /// The power hold and the scene, recorded instead of held and drawn.
    final class FakeKeepAwake: SleepyKeepAwakeHolding {
        var isHolding = false
        var begins = 0
        func begin() { if !isHolding { begins += 1 }; isHolding = true }
        func end() { isHolding = false }
    }

    final class FakeOverlay: SleepyOverlayPresenting {
        var wake: (@MainActor () -> Void)?
        var isShowing: Bool { wake != nil }
        func show(wake: @escaping @MainActor () -> Void) { self.wake = wake }
        func hide() { wake = nil }
    }

    static func fakeServices() -> (AppServices, FakeKeepAwake, FakeOverlay) {
        let services = services()
        let keepAwake = FakeKeepAwake(), overlay = FakeOverlay()
        services.sleepyMode = SleepyModeController(keepAwake: keepAwake, overlay: overlay)
        return (services, keepAwake, overlay)
    }

    @Test func runningTheActionHoldsTheMacAwakeAndShowsTheSceneUntilRunAgain() {
        let (services, keepAwake, overlay) = Self.fakeServices()
        #expect(services.registry.perform("palette.sleepyMode"))
        #expect(services.sleepyMode.isActive)
        #expect(keepAwake.isHolding, "the Mac and its display stay awake")
        #expect(overlay.isShowing)
        #expect(services.registry.perform("palette.sleepyMode"))
        #expect(!services.sleepyMode.isActive)
        #expect(!keepAwake.isHolding, "waking lets the Mac sleep again")
        #expect(!overlay.isShowing)
    }

    /// A click on the scene (its wake callback) ends Sleepy Mode and its hold.
    @Test func aClickOnTheSceneWakesIt() throws {
        let (services, keepAwake, overlay) = Self.fakeServices()
        services.registry.perform("palette.sleepyMode")
        let wake = try #require(overlay.wake)
        wake()
        #expect(!services.sleepyMode.isActive)
        #expect(!keepAwake.isHolding)
        #expect(!overlay.isShowing)
    }

    /// A key while the scene shows wakes it and goes no further (no shortcut runs behind it);
    /// a key without Sleepy Mode passes through.
    @Test func aKeyWakesTheSceneAndIsConsumed() {
        let (services, keepAwake, _) = Self.fakeServices()
        #expect(!services.sleepyMode.consumesKeyDown(), "no Sleepy Mode: the key goes on")
        services.registry.perform("palette.sleepyMode")
        #expect(services.sleepyMode.consumesKeyDown())
        #expect(!services.sleepyMode.isActive)
        #expect(!keepAwake.isHolding)
        #expect(!services.sleepyMode.consumesKeyDown())
    }

    /// Turning it on twice holds once; turning it off twice is harmless.
    @Test func turningItOnTwiceHoldsOnce() {
        let keepAwake = FakeKeepAwake(), overlay = FakeOverlay()
        let controller = SleepyModeController(keepAwake: keepAwake, overlay: overlay)
        controller.activate()
        controller.activate()
        #expect(keepAwake.begins == 1)
        controller.deactivate()
        controller.deactivate()
        #expect(!keepAwake.isHolding)
    }

    /// The real activity holds and releases (`ProcessInfo` keep-awake, display included).
    @Test func theRealActivityHoldsAndReleases() {
        let activity = SleepyKeepAwakeActivity()
        activity.begin()
        #expect(activity.isHolding)
        activity.end()
        #expect(!activity.isHolding)
    }
}
