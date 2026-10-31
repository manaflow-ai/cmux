import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextTerminal

/// The app as a test host makes it: one place that does what the app's launch does before it makes `AppServices`.
/// The app makes its services only once libghostty's app started (`AppDelegate`: `finishLaunching` runs in the `then:`
/// of `GhosttyRuntime.start(loadingOn:)`), so a terminal view always has a surface; a test host runs no launch, and a
/// view made before the runtime started had no surface and took no keys (since a649fdca30f:
/// SwitchToColdTabTypeAheadTests and the P0 typing tests on perf). A live-daemon harness makes its services here.
@MainActor enum TestHosts {
    /// The app's services with the shared Ghostty runtime started and the actions bound, as the launch has them.
    static func liveDaemonApp(environment: [String: String] = [:]) -> AppServices {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let services = AppServices(environment: AppEnvironment.current(environment))
        AppActions.bind(services)
        return services
    }
}
