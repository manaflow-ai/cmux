public import Foundation

/// The app-coupled side effects a ``MenuBarExtraPresentationCoordinator`` fires
/// while it drives the menu-bar-extra presentation lifecycle.
///
/// The coordinator owns the window-agnostic state (the persistent / transient
/// ``MenuBarExtraControlling`` instances, the `UserDefaults.didChangeNotification`
/// observer tokens, and the last-install latch). Everything it cannot do itself is
/// injected here as `@MainActor` closures:
///
/// - ``makeController`` builds a fresh app-target `MenuBarExtraController` (it wires
///   the `NSStatusBarButton` / `GlobalSearchCoordinator` / `MobileHostService` /
///   `TaskManagerWindowController` / `NSApp` / settings-window / main-window /
///   notification effects that all stay app-side).
/// - ``shouldInstallMenuBarExtra`` reads `MenuBarExtraSettings` for the current
///   `UserDefaults`.
/// - ``normalizeLegacyStoredPreference`` and ``applyActivationPolicy`` forward to
///   `MenuBarOnlySettings`.
/// - ``syncMobileHostService`` forwards to `MobileHostService.shared.syncToSettings()`.
/// - ``log`` emits a DEBUG diagnostic line (a no-op in release).
///
/// This keeps the coordinator free of any AppKit / app-singleton dependency while
/// preserving the original behavior exactly.
public struct MenuBarExtraPresentationEffects: Sendable {
    /// Builds a fresh menu-bar-extra controller wired to the app's effects.
    public var makeController: @MainActor () -> any MenuBarExtraControlling

    /// Reports whether the menu-bar extra should be installed for the given defaults.
    public var shouldInstallMenuBarExtra: @MainActor (_ defaults: UserDefaults) -> Bool

    /// Normalizes the legacy menu-bar-only stored preference for the given defaults.
    public var normalizeLegacyStoredPreference: @MainActor (_ defaults: UserDefaults) -> Void

    /// Applies the menu-bar-only activation policy for the given defaults.
    public var applyActivationPolicy: @MainActor (_ defaults: UserDefaults) -> Void

    /// Syncs the mobile-host service to current settings.
    public var syncMobileHostService: @MainActor () -> Void

    /// Emits a DEBUG diagnostic line.
    public var log: @MainActor (_ message: String) -> Void

    /// Creates an effects bundle.
    public init(
        makeController: @escaping @MainActor () -> any MenuBarExtraControlling,
        shouldInstallMenuBarExtra: @escaping @MainActor (_ defaults: UserDefaults) -> Bool,
        normalizeLegacyStoredPreference: @escaping @MainActor (_ defaults: UserDefaults) -> Void,
        applyActivationPolicy: @escaping @MainActor (_ defaults: UserDefaults) -> Void,
        syncMobileHostService: @escaping @MainActor () -> Void,
        log: @escaping @MainActor (_ message: String) -> Void = { _ in }
    ) {
        self.makeController = makeController
        self.shouldInstallMenuBarExtra = shouldInstallMenuBarExtra
        self.normalizeLegacyStoredPreference = normalizeLegacyStoredPreference
        self.applyActivationPolicy = applyActivationPolicy
        self.syncMobileHostService = syncMobileHostService
        self.log = log
    }
}
