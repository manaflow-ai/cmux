import Foundation
import Observation

/// Publishes only settings changes rendered by the window composition root.
@MainActor
@Observable
final class ContentViewDefaultsStore {
    private(set) var snapshot: ContentViewDefaultsSnapshot

    @ObservationIgnored
    private let defaults: UserDefaults
    @ObservationIgnored
    private var observer: NSObjectProtocol?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        snapshot = ContentViewDefaultsSnapshot(defaults: defaults)
        let defaultsID = ObjectIdentifier(defaults)
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let object = notification.object {
                guard ObjectIdentifier(object as AnyObject) == defaultsID else { return }
            }
            MainActor.assumeIsolated { [weak self] in
                self?.refresh()
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func toggleSidebarMatchTerminalBackground() {
        let key = "sidebarMatchTerminalBackground"
        defaults.set(
            !defaults.bool(forKey: key),
            forKey: key
        )
    }

    private func refresh() {
        let nextSnapshot = ContentViewDefaultsSnapshot(defaults: defaults)
        guard nextSnapshot != snapshot else { return }
        snapshot = nextSnapshot
    }
}
