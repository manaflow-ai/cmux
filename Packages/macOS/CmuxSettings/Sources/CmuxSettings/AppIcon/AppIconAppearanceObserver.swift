import Foundation

/// Observes the system appearance while the app icon is in ``AppIconMode/automatic``
/// and reapplies the light/dark dock icon when the appearance flips.
///
/// Owns the `effectiveAppearance` KVO lifecycle through the AppKit-free
/// ``AppIconAppearanceObservation`` seam, plus a one-shot launch observer so the
/// first apply is deferred until `applicationDidFinishLaunching` (Tahoe crashes
/// if `effectiveAppearance` is touched during `App.init()`). The
/// ``lastAppliedImageName`` dedup is pure logic kept here so an unchanged
/// appearance never re-sets the runtime icon.
///
/// Isolation: `@MainActor`. Every collaborator (NSApp appearance reads, setting
/// the runtime icon, the KVO callback delivery) is main-thread AppKit work, so
/// the observer lives where its callers live and holds its mutable observation
/// tokens without a lock. Constructor-injected ``Environment`` keeps it testable
/// and AppKit out of the settings package; the live environment is built app-side.
@MainActor
public final class AppIconAppearanceObserver {
    /// Injected collaborators expressed in AppKit-free terms so the settings
    /// package never names an AppKit type.
    public struct Environment {
        /// Whether `applicationDidFinishLaunching` has run.
        public let isApplicationFinishedLaunching: () -> Bool
        /// Starts KVO of `effectiveAppearance`, invoking the handler on each
        /// change; returns the cancellable token, or `nil` when no app exists.
        public let startEffectiveAppearanceObservation: (@escaping () -> Void) -> AppIconAppearanceObservation?
        /// Registers a one-shot launch observer; returns a token whose
        /// `invalidate()` removes it.
        public let addDidFinishLaunchingObserver: (@escaping () -> Void) -> AppIconAppearanceObservation
        /// `true`/`false` for the current dark/light appearance, or `nil` when
        /// no app exists.
        public let currentAppearanceIsDark: () -> Bool?
        /// Sets the runtime dock icon to the named asset; returns whether an
        /// image existed and was applied.
        public let applyIconImage: (String) -> Bool

        /// Creates an environment from its collaborators.
        public init(
            isApplicationFinishedLaunching: @escaping () -> Bool,
            startEffectiveAppearanceObservation: @escaping (@escaping () -> Void) -> AppIconAppearanceObservation?,
            addDidFinishLaunchingObserver: @escaping (@escaping () -> Void) -> AppIconAppearanceObservation,
            currentAppearanceIsDark: @escaping () -> Bool?,
            applyIconImage: @escaping (String) -> Bool
        ) {
            self.isApplicationFinishedLaunching = isApplicationFinishedLaunching
            self.startEffectiveAppearanceObservation = startEffectiveAppearanceObservation
            self.addDidFinishLaunchingObserver = addDidFinishLaunchingObserver
            self.currentAppearanceIsDark = currentAppearanceIsDark
            self.applyIconImage = applyIconImage
        }
    }

    private let environment: Environment
    private var observation: AppIconAppearanceObservation?
    private var launchObserver: AppIconAppearanceObservation?
    private var hasDeferredStartPending = false
    private var lastAppliedImageName: String?

    /// Creates an observer driven by the given environment.
    public init(environment: Environment) {
        self.environment = environment
    }

    /// Begins observing the system appearance, deferring the first apply until
    /// launch completes if needed.
    public func startObserving() {
        // Tahoe crashes if effectiveAppearance is touched during App.init(),
        // so defer the first automatic-icon apply until launch completes.
        if !environment.isApplicationFinishedLaunching() {
            deferStartUntilLaunchIfNeeded()
            return
        }

        cancelDeferredStart()
        applyIconForCurrentAppearance()
        guard observation == nil else { return }
        observation = environment.startEffectiveAppearanceObservation { [weak self] in
            guard let self, self.observation != nil else { return }
            self.applyIconForCurrentAppearance()
        }
    }

    /// Stops observing and clears the dedup state.
    public func stopObserving() {
        observation?.invalidate()
        observation = nil
        lastAppliedImageName = nil
        cancelDeferredStart()
    }

    private func deferStartUntilLaunchIfNeeded() {
        hasDeferredStartPending = true
        guard launchObserver == nil else { return }
        launchObserver = environment.addDidFinishLaunchingObserver { [weak self] in
            guard let self, self.hasDeferredStartPending else { return }
            self.cancelDeferredStart()
            self.startObserving()
        }
    }

    private func cancelDeferredStart() {
        hasDeferredStartPending = false
        guard let launchObserver else { return }
        launchObserver.invalidate()
        self.launchObserver = nil
    }

    private func applyIconForCurrentAppearance() {
        guard environment.isApplicationFinishedLaunching() else { return }
        guard let isDark = environment.currentAppearanceIsDark() else { return }
        let imageName = isDark ? "AppIconDark" : "AppIconLight"
        guard imageName != lastAppliedImageName else { return }
        guard environment.applyIconImage(imageName) else { return }
        lastAppliedImageName = imageName
    }
}
