import Foundation
import Observation

/// Precise invalidation source for the extension-sidebar provider selection.
/// `@AppStorage` cannot observe `cmuxExtensionSidebar.providerId` per key (the
/// dot breaks KVO key registration and SwiftUI falls back to invalidating the
/// holder on every `UserDefaults` write), which re-ran the entire
/// `VerticalTabsSidebar` body — O(N) workspace-row render context — on any
/// defaults change, including the minimal-mode toggle
/// (https://github.com/manaflow-ai/cmux/issues/5732). This model re-checks the
/// stored value on `UserDefaults.didChangeNotification` and mutates
/// `providerId` only when it actually changed, so Observation-tracked readers
/// re-render only on real provider changes.
@MainActor
@Observable
final class ExtensionSidebarProviderSelectionModel {
    static let shared = ExtensionSidebarProviderSelectionModel()

    private(set) var providerId: String

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var observer: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        providerId = defaults.string(forKey: CmuxExtensionSidebarSelection.defaultsKey)
            ?? CmuxExtensionSidebarSelection.defaultProviderId
        // OS notification boundary: UserDefaults has no per-key async API for
        // dotted keys, so observe the coarse didChange signal and filter.
        // `queue: nil` delivers synchronously on the posting thread; every
        // in-app mutation path writes defaults on the main thread, so the
        // refresh lands in the same turn (and deterministically in tests).
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: nil
        ) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.refreshFromDefaults()
                }
            } else {
                Task { @MainActor [weak self] in
                    self?.refreshFromDefaults()
                }
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func refreshFromDefaults() {
        let next = defaults.string(forKey: CmuxExtensionSidebarSelection.defaultsKey)
            ?? CmuxExtensionSidebarSelection.defaultProviderId
        if providerId != next {
            providerId = next
        }
    }
}
