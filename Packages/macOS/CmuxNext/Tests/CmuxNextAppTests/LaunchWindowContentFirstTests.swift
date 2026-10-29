import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// Leo's never-blank first launch frame: a window is ordered in with its content
/// already installed. A restore launch's window drew one solid white frame at
/// 1830 ms (the backdrop alone) because `makeController` presented it in the
/// turn it was made, and its workspace (the launch snapshot's, else the
/// connecting state) went in a main-actor hop later.
@MainActor @Suite(.serialized)
struct LaunchWindowContentFirstTests {
    @MainActor private final class Presented {
        var installed: [Bool] = []
    }

    @Test func theLaunchWindowIsOrderedInWithItsContentInstalled() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let presented = Presented()
        // The hook runs as each window is ordered in, before AppKit draws it.
        services.windows.onPresent = { controller in
            presented.installed.append(controller.content != nil || controller.connectingView != nil)
        }
        services.windows.restoreWhenLoaded()
        defer { for controller in services.windows.controllers { controller.window?.close() } }

        #expect(presented.installed == [true], "the launch window was ordered in before its content: a frame of backdrop alone")
    }
}
