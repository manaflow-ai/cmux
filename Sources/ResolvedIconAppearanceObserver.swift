import AppKit

@MainActor
final class ResolvedIconAppearanceObserver {
    struct Environment {
        let isApplicationFinishedLaunching: () -> Bool
        let startEffectiveAppearanceObservation: (@escaping () -> Void) -> NSKeyValueObservation?
        let addDidFinishLaunchingObserver: (@escaping () -> Void) -> NSObjectProtocol
        let removeObserver: (NSObjectProtocol) -> Void
        let syncResolvedIcons: () -> Void

        static func live() -> Self {
            Self(
                isApplicationFinishedLaunching: {
                    AppIconLaunchState.isApplicationFinishedLaunching()
                },
                startEffectiveAppearanceObservation: { handler in
                    NSApplication.shared.observe(\.effectiveAppearance, options: []) { _, _ in
                        Task { @MainActor in
                            handler()
                        }
                    }
                },
                addDidFinishLaunchingObserver: { handler in
                    NotificationCenter.default.addObserver(
                        forName: NSApplication.didFinishLaunchingNotification,
                        object: nil,
                        queue: .main
                    ) { _ in
                        handler()
                    }
                },
                removeObserver: { observer in
                    NotificationCenter.default.removeObserver(observer)
                },
                syncResolvedIcons: {
                    AppDelegate.shared?.syncResolvedIconImagesForCurrentAppearance()
                }
            )
        }
    }

    private let environment: Environment
    private var observation: NSKeyValueObservation?
    private var launchObserver: NSObjectProtocol?
    private var hasDeferredStartPending = false

    init(environment: Environment = .live()) {
        self.environment = environment
    }

    func startObserving() {
        if !environment.isApplicationFinishedLaunching() {
            deferStartUntilLaunchIfNeeded()
            return
        }
        cancelDeferredStart()
        syncNow()
        guard observation == nil else { return }
        observation = environment.startEffectiveAppearanceObservation { [weak self] in
            self?.syncNow()
        }
    }

    func syncNow() {
        environment.syncResolvedIcons()
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
        if let launchObserver {
            environment.removeObserver(launchObserver)
            self.launchObserver = nil
        }
    }
}
