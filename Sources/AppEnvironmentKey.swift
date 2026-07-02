import SwiftUI

/// SwiftUI environment carrier for the process-lifetime ``AppEnvironment`` the
/// app owns at its composition root (`AppDelegate`).
///
/// AppKit hosts each main window's `ContentView` in its own `NSHostingView`,
/// which does not inherit the App scene's SwiftUI environment. The composition
/// root injects its owned ``AppEnvironment`` via
/// `.environment(\.appEnvironment, …)` at the per-window root view so any View
/// below can read process-lifetime services through `@Environment(\.appEnvironment)`
/// instead of reaching `AppDelegate.shared`.
///
/// The default is `nil`, matching the legacy fallback: `AppDelegate.shared?` was
/// optional, so a reader with no injected environment short-circuits exactly as
/// `AppDelegate.shared?.notificationStore` did when the delegate was unavailable
/// (`appEnvironment?.notificationStore`).
private struct AppEnvironmentKey: EnvironmentKey {
    static let defaultValue: AppEnvironment? = nil
}

extension EnvironmentValues {
    /// The process-lifetime ``AppEnvironment`` injected from the app composition
    /// root, or `nil` when none has been injected.
    var appEnvironment: AppEnvironment? {
        get { self[AppEnvironmentKey.self] }
        set { self[AppEnvironmentKey.self] = newValue }
    }
}
