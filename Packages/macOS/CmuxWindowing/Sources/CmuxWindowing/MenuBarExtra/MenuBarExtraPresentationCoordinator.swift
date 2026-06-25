public import Foundation
public import Observation

/// `@MainActor @Observable` owner of the menu-bar-extra presentation lifecycle.
///
/// This is the seam the app target's `AppDelegate` forwards through. The coordinator
/// owns the window-agnostic state: the persistent and transient
/// ``MenuBarExtraControlling`` instances, the two `UserDefaults.didChangeNotification`
/// observer tokens (menu-bar visibility + mobile-host), and the last-install latch.
/// The AppKit-coupled work (building a controller, the global-search palette window,
/// `NSApp` activation policy, settings/notification windows) stays app-side and is
/// injected as ``MenuBarExtraPresentationEffects`` closures or reached through the
/// ``MenuBarExtraControlling`` seam.
///
/// ## Isolation
///
/// Every mutator runs on the main actor: app launch, settings-window toggles, the
/// global hotkey, and the `UserDefaults` change observers all reach palette/menu-bar
/// state on main. So the coordinator is `@MainActor` and co-locates its state with
/// its callers; there is no actor hop and no lock. It does no I/O itself.
///
/// The `NotificationCenter` observer closures are marked `@Sendable` so that, formed
/// inside this `@MainActor` type, they do not inherit main-actor isolation and trap
/// when `NotificationCenter` invokes them; they hop to the main actor explicitly,
/// matching the legacy `queue: .main` + inner `Task { @MainActor }` shape exactly.
@MainActor
@Observable
public final class MenuBarExtraPresentationCoordinator {
    @ObservationIgnored private let effects: MenuBarExtraPresentationEffects

    /// The persistent menu-bar-extra controller, present while the extra is installed.
    @ObservationIgnored private var menuBarExtraController: (any MenuBarExtraControlling)?
    /// The transient controller used to present the global-search palette when no
    /// persistent controller exists; torn down on dismissal.
    @ObservationIgnored private var transientGlobalSearchMenuBarExtraController: (any MenuBarExtraControlling)?
    /// The last computed install decision, used to decide whether a transient
    /// controller must also be removed when the extra is hidden.
    @ObservationIgnored private var lastMenuBarExtraShouldInstall: Bool?
    /// The `UserDefaults.didChangeNotification` observer driving presentation sync.
    @ObservationIgnored private var menuBarVisibilityObserver: (any NSObjectProtocol)?
    /// The `UserDefaults.didChangeNotification` observer driving mobile-host sync.
    @ObservationIgnored private var mobileHostSettingsObserver: (any NSObjectProtocol)?

    /// Creates a coordinator.
    ///
    /// - Parameter effects: the app-coupled side effects.
    public init(effects: MenuBarExtraPresentationEffects) {
        self.effects = effects
    }

    // MARK: Setup

    /// Installs the persistent menu-bar-extra controller if one is not already present,
    /// removing any transient controller first.
    private func setupMenuBarExtra() {
        guard menuBarExtraController == nil else { return }
        removeTransientGlobalSearchMenuBarExtraController()
        menuBarExtraController = effects.makeController()
    }

    /// Re-renders the persistent controller's debug-only menu affordances, if one is
    /// installed.
    public func refreshForDebug() {
        menuBarExtraController?.refreshForDebugControls()
    }

    // MARK: Global search palette

    /// Toggles the global-search palette from the global hotkey, lazily installing the
    /// persistent controller if settings request it and falling back to a transient
    /// controller, beeping only when neither can present.
    ///
    /// - Returns: `true` if the palette was toggled, `false` if the caller should beep.
    public func toggleGlobalSearchPaletteFromGlobalHotkey(defaults: UserDefaults = .standard) -> Bool {
        if menuBarExtraController == nil,
           effects.shouldInstallMenuBarExtra(defaults) {
            setupMenuBarExtra()
        }

        if let menuBarExtraController,
           menuBarExtraController.togglePersistentGlobalSearchPalette() {
            return true
        }

        if toggleGlobalSearchPaletteFromTransientMenuBarExtra() {
            return true
        }

        return false
    }

    private func toggleGlobalSearchPaletteFromTransientMenuBarExtra() -> Bool {
        if let controller = transientGlobalSearchMenuBarExtraController {
            if controller.toggleTransientGlobalSearchPalette(
                onDismiss: transientGlobalSearchDismissalHandler(for: controller)
            ) {
                return true
            }
            controller.removeFromMenuBar()
            transientGlobalSearchMenuBarExtraController = nil
        }

        let controller = effects.makeController()
        transientGlobalSearchMenuBarExtraController = controller

        let onDismiss = transientGlobalSearchDismissalHandler(for: controller)

        guard controller.toggleTransientGlobalSearchPalette(onDismiss: onDismiss) else {
            controller.removeFromMenuBar()
            transientGlobalSearchMenuBarExtraController = nil
            return false
        }

        return true
    }

    private func removeTransientGlobalSearchMenuBarExtraController() {
        transientGlobalSearchMenuBarExtraController?.removeFromMenuBar()
        transientGlobalSearchMenuBarExtraController = nil
    }

    private func transientGlobalSearchDismissalHandler(
        for controller: any MenuBarExtraControlling
    ) -> () -> Void {
        return { [weak self, weak controller] in
            guard let self,
                  let controller,
                  self.transientGlobalSearchMenuBarExtraController === controller else {
                return
            }
            controller.removeFromMenuBar()
            self.transientGlobalSearchMenuBarExtraController = nil
        }
    }

    // MARK: Observers

    /// Installs the `UserDefaults` change observer that re-syncs application
    /// presentation preferences (activation policy + menu-bar-extra visibility).
    public func installMenuBarVisibilityObserver() {
        guard menuBarVisibilityObserver == nil else { return }
        menuBarVisibilityObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncApplicationPresentationPreferences()
            }
        }
    }

    /// Re-applies the activation policy and menu-bar-extra visibility for the given
    /// defaults, normalizing the legacy stored preference first.
    public func syncApplicationPresentationPreferences(defaults: UserDefaults = .standard) {
        effects.normalizeLegacyStoredPreference(defaults)
        syncActivationPolicy(defaults: defaults)
        syncMenuBarExtraVisibility(defaults: defaults)
    }

    /// Installs the `UserDefaults` change observer that re-syncs the mobile-host
    /// service to settings.
    public func installMobileHostSettingsObserver() {
        guard mobileHostSettingsObserver == nil else { return }
        mobileHostSettingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncMobileHostService()
            }
        }
    }

    private func syncMobileHostService() {
        effects.syncMobileHostService()
    }

    /// Applies the menu-bar-only activation policy for the given defaults.
    public func syncActivationPolicy(defaults: UserDefaults = .standard) {
        effects.applyActivationPolicy(defaults)
    }

    private func syncMenuBarExtraVisibility(defaults: UserDefaults = .standard) {
        let shouldInstall = effects.shouldInstallMenuBarExtra(defaults)
        let previousShouldInstall = lastMenuBarExtraShouldInstall
        lastMenuBarExtraShouldInstall = shouldInstall

        if shouldInstall {
            setupMenuBarExtra()
            return
        }

        let hadPersistentController = menuBarExtraController != nil
        menuBarExtraController?.removeFromMenuBar()
        menuBarExtraController = nil
        if previousShouldInstall == true || hadPersistentController {
            removeTransientGlobalSearchMenuBarExtraController()
        }
    }
}
