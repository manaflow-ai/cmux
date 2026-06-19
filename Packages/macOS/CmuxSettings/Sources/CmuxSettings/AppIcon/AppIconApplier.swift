import Foundation

/// Applies the persisted app-icon mode to the running app: starts/stops the
/// appearance observer for ``AppIconMode/automatic``, sets the pinned light/dark
/// dock icon otherwise, and pings the dock-tile plugin so a Dock-hosted process
/// refreshes its tile.
///
/// Reads the persisted mode through ``AppIconSettingsStore``; applying the icon
/// to `NSApplication` and driving the appearance observer is host work injected
/// through ``Environment``. This is the injected service that replaces the
/// former `AppIconSettings` static facade and its mutable `liveEnvironmentProvider`
/// static — one instance is constructed at the app composition root and held by
/// the callers that need it.
///
/// Isolation: `@MainActor`. Setting `NSApplication.applicationIconImage` and
/// starting/stopping the appearance observer are main-thread AppKit operations,
/// so the service lives where its callers (`applicationDidFinishLaunching`,
/// settings-change handlers) already run.
@MainActor
public final class AppIconApplier {
    /// Injected collaborators expressed in AppKit-free terms.
    public struct Environment {
        /// Whether `applicationDidFinishLaunching` has run.
        public let isApplicationFinishedLaunching: () -> Bool
        /// Applies the pinned light/dark dock icon for the given non-automatic
        /// mode (resolves the asset image and sets it; no-op if absent).
        public let applyManualIcon: (AppIconMode) -> Void
        /// Starts the system-appearance observation (automatic mode).
        public let startAppearanceObservation: () -> Void
        /// Stops the system-appearance observation (manual modes).
        public let stopAppearanceObservation: () -> Void
        /// Notifies the dock-tile plugin that the icon changed.
        public let notifyDockTilePlugin: () -> Void

        /// Creates an environment from its collaborators.
        public init(
            isApplicationFinishedLaunching: @escaping () -> Bool,
            applyManualIcon: @escaping (AppIconMode) -> Void,
            startAppearanceObservation: @escaping () -> Void,
            stopAppearanceObservation: @escaping () -> Void,
            notifyDockTilePlugin: @escaping () -> Void
        ) {
            self.isApplicationFinishedLaunching = isApplicationFinishedLaunching
            self.applyManualIcon = applyManualIcon
            self.startAppearanceObservation = startAppearanceObservation
            self.stopAppearanceObservation = stopAppearanceObservation
            self.notifyDockTilePlugin = notifyDockTilePlugin
        }
    }

    private let store: AppIconSettingsStore
    private let environment: Environment

    /// Creates an applier reading the given store and driving the given environment.
    public init(store: AppIconSettingsStore, environment: Environment) {
        self.store = store
        self.environment = environment
    }

    /// The persisted icon mode; unrecognized stored values read as ``AppIconMode/automatic``.
    public var resolvedMode: AppIconMode {
        store.resolvedMode
    }

    /// Applies the persisted icon mode.
    public func applyResolvedMode() {
        apply(resolvedMode)
    }

    /// Applies the given icon mode to the running app.
    public func apply(_ mode: AppIconMode) {
        // Tahoe can crash or wedge when app icon work runs during App.init(),
        // so leave settings replay to update defaults only and let the launch
        // path apply the resolved icon once didFinishLaunching begins.
        guard environment.isApplicationFinishedLaunching() else { return }

        switch mode {
        case .automatic:
            environment.startAppearanceObservation()
        case .light:
            environment.stopAppearanceObservation()
            environment.applyManualIcon(.light)
        case .dark:
            environment.stopAppearanceObservation()
            environment.applyManualIcon(.dark)
        }

        environment.notifyDockTilePlugin()
    }
}
