import AppKit
import Foundation

extension Notification.Name {
    /// Posted by SystemAppearanceObserver when NSApp.effectiveAppearance changes (#6385).
    static let systemAppearanceDidChange = Notification.Name("cmux.systemAppearanceDidChange")
}

extension NSAppearance {
    /// True when this appearance resolves to a dark variant.
    var cmuxPrefersDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

/// Shared observation contract used by `AppIconAppearanceObserver` (cmuxApp.swift)
/// and `SystemAppearanceObserver`.
protocol EffectiveAppearanceObservation: AnyObject {
    func invalidate()
}

extension NSKeyValueObservation: EffectiveAppearanceObservation {}

/// Keeps the app chrome in sync with live macOS appearance changes while the
/// appearance mode is `system`.
///
/// With `NSApplication.appearance == nil`, AppKit updates `effectiveAppearance`
/// when the OS switches Light/Dark, but the SwiftUI hosting layer does not
/// reliably re-resolve the ambient `colorScheme` for already-visible windows
/// (visible when the switch is triggered by Shortcuts' "Set Appearance" or the
/// scheduled Auto switch, #6385). This observer is detect-and-notify only: it
/// KVO-watches `NSApp.effectiveAppearance` and, in system mode, diffs the
/// freshly resolved value against the last-resolved one, and — only on an
/// actual change — posts `.systemAppearanceDidChange` so interested views
/// (see `AppearanceColorSchemeModifier`) can re-resolve their color scheme
/// directly from `NSApp.effectiveAppearance` and force a body recomputation.
///
/// It is intentionally separate from `AppIconAppearanceObserver`, which observes
/// the same key path but is torn down whenever the app icon isn't in automatic
/// mode, so it cannot be relied upon to refresh app chrome. The two observers
/// own different lifecycles on purpose: the icon observer's teardown is keyed
/// to icon mode, while chrome refresh must stay armed for the whole app
/// lifetime — a single shared observer would couple those lifecycles.
///
/// The AppleInterfaceStyle default is NOT a reliable fresh source here: on
/// scripted appearance changes (Shortcuts "Set Appearance"), this process's
/// CFPreferences view of the global domain can remain stale long after AppKit
/// has resolved the new effectiveAppearance — runtime traces show both the
/// direct and globalDomain reads returning the pre-toggle value.
/// effectiveAppearance is the ground truth for this observer.
@MainActor
final class SystemAppearanceObserver {
    struct Environment {
        let startEffectiveAppearanceObservation: (@escaping () -> Void) -> EffectiveAppearanceObservation?
        let currentAppearanceModeRawValue: () -> String?
        let effectivePrefersDark: () -> Bool
        let postSystemAppearanceDidChange: () -> Void

        static func live() -> Environment {
            Environment(
                startEffectiveAppearanceObservation: { handler in
                    // `Environment` is nested in the now-`@MainActor` `SystemAppearanceObserver`,
                    // which makes the compiler check this closure's body for actor-isolation
                    // crossings even though `startEffectiveAppearanceObservation`'s declared type
                    // stays plain/non-isolated. `startObserving()` (the only caller) is
                    // main-actor-isolated, so this always runs on the main actor in practice;
                    // `assumeIsolated` makes that explicit for the type checker.
                    MainActor.assumeIsolated {
                        guard let app = NSApp else { return nil }
                        return app.observe(\.effectiveAppearance, options: []) { _, _ in
                            DispatchQueue.main.async { handler() }
                        }
                    }
                },
                currentAppearanceModeRawValue: {
                    UserDefaults.standard.string(forKey: AppearanceSettings.appearanceModeKey)
                },
                effectivePrefersDark: {
                    MainActor.assumeIsolated {
                        NSApp?.effectiveAppearance.cmuxPrefersDark == true
                    }
                },
                postSystemAppearanceDidChange: {
                    NotificationCenter.default.post(name: .systemAppearanceDidChange, object: nil)
                }
            )
        }
    }

    static let shared = SystemAppearanceObserver()

    private let environment: Environment
    private var observation: EffectiveAppearanceObservation?
    private var lastResolvedPrefersDark: Bool?

    init(environment: Environment = .live()) {
        self.environment = environment
    }

    func startObserving() {
        guard observation == nil else { return }
        lastResolvedPrefersDark = environment.effectivePrefersDark()
        observation = environment.startEffectiveAppearanceObservation { [weak self] in
            // `startEffectiveAppearanceObservation`'s handler parameter is plain/non-isolated
            // (see `Environment.live()`), but it is only ever invoked via
            // `DispatchQueue.main.async` there, so this always runs on the main actor.
            MainActor.assumeIsolated {
                self?.handleEffectiveAppearanceChange()
            }
        }
    }

    // No deinit: `shared` never deallocates, and `NSKeyValueObservation` (the
    // concrete `EffectiveAppearanceObservation` returned by
    // `startEffectiveAppearanceObservation`) self-invalidates at dealloc anyway.
    func stopObserving() {
        observation?.invalidate()
        observation = nil
    }

    private func handleEffectiveAppearanceChange() {
        // Stale-fire guard: the KVO handler can still be in flight (or
        // re-entrantly triggered, see below) after `stopObserving()` has run.
        guard observation != nil else { return }
        guard AppearanceSettings.mode(for: environment.currentAppearanceModeRawValue()) == .system else { return }
        let prefersDark = environment.effectivePrefersDark()
        guard prefersDark != lastResolvedPrefersDark else { return }
        lastResolvedPrefersDark = prefersDark
        cmuxDebugLog("systemAppearance.observer.change prefersDark=\(prefersDark)")
        environment.postSystemAppearanceDidChange()
    }
}

/// Launch-seam starter for the appearance observers armed in
/// `applicationDidFinishLaunching`. `SystemAppearanceObserver` keeps app chrome
/// following live OS appearance switches (Shortcuts/scheduled Auto) while in
/// system mode; it must start here, past the App.init() effectiveAppearance
/// crash window (#6385).
@MainActor
enum AppearanceObservers {
    static func startAtLaunch() {
        AppearanceSettingsUserDefaultsObserver.shared.startObserving()
        SystemAppearanceObserver.shared.startObserving()
    }
}

enum GhosttyAppearanceSync {
    /// Resolves the terminal color-scheme preference for an appearance-sync pass.
    ///
    /// `passedAppearance` comes from AppKit's live appearance cascade (a view's
    /// `effectiveAppearance`, or an explicit app-level override). On scripted
    /// OS appearance changes (e.g. Shortcuts' "Set Appearance"), that cascade
    /// stays fresh, while this process's CFPreferences view of
    /// `AppleInterfaceStyle` (what the defaults-based resolution below reads)
    /// can remain stale on exactly that path. So when the app is following
    /// the system (`AppearanceMode.system`) and a non-nil appearance was
    /// passed in, it is the more trustworthy source and wins over the
    /// defaults-based read. Explicit light/dark modes always win over both,
    /// and a `nil` appearance (as passed by `AppearanceSettings.applyLiveMode`
    /// when steady-state in system mode) falls back to the existing
    /// defaults-based resolution unchanged.
    static func resolveColorSchemePreference(
        passedAppearance: NSAppearance?
    ) -> (preference: GhosttyConfig.ColorSchemePreference, usedPassedAppearance: Bool) {
        let isSystemMode = AppearanceSettings.mode(
            for: UserDefaults.standard.string(forKey: AppearanceSettings.appearanceModeKey)
        ) == .system
        let usedPassedAppearance = isSystemMode && passedAppearance != nil
        let currentColorScheme: GhosttyConfig.ColorSchemePreference
        if isSystemMode, let passedAppearance {
            currentColorScheme = passedAppearance.cmuxPrefersDark ? .dark : .light
        } else {
            currentColorScheme = GhosttyConfig.currentColorSchemePreference()
        }
        return (preference: currentColorScheme, usedPassedAppearance: usedPassedAppearance)
    }
}
