import AppKit

@MainActor
final class ResolvedIconAppearanceObserver {
    static let shared = ResolvedIconAppearanceObserver()

    private var observation: NSKeyValueObservation?
    private var launchObserver: NSObjectProtocol?
    private var hasDeferredStartPending = false

    private init() {}

    func startObserving() {
        if !AppIconLaunchState.isApplicationFinishedLaunching() {
            deferStartUntilLaunchIfNeeded()
            return
        }
        cancelDeferredStart()
        syncNow()
        guard observation == nil else { return }
        observation = NSApplication.shared.observe(\.effectiveAppearance, options: []) { _, _ in
            Task { @MainActor in
                ResolvedIconAppearanceObserver.shared.syncNow()
            }
        }
    }

    func syncNow() {
        AppDelegate.shared?.syncResolvedIconImagesForCurrentAppearance()
    }

    private func deferStartUntilLaunchIfNeeded() {
        hasDeferredStartPending = true
        guard launchObserver == nil else { return }
        launchObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.hasDeferredStartPending else { return }
            self.cancelDeferredStart()
            self.startObserving()
        }
    }

    private func cancelDeferredStart() {
        hasDeferredStartPending = false
        if let launchObserver {
            NotificationCenter.default.removeObserver(launchObserver)
            self.launchObserver = nil
        }
    }
}
