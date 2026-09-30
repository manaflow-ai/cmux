import CmuxNextSettings
import Observation

/// The live `browser.defaultEngine`: follows cmux.json, and the default
/// engine actions set it at once before their file write comes back through
/// the watcher (like density). Observable so the Chromium warm-start policy
/// can follow it.
@MainActor
@Observable
final class BrowserEnginePreference {
    var defaultEngine: BrowserDefaultEngine = .fallback
    @ObservationIgnored private var observation: Task<Void, Never>?

    /// Applies every loaded snapshot's value.
    func follow(_ settings: SettingsController) {
        observation?.cancel()
        observation = Task { [weak self] in
            for await engine in Observations({ settings.snapshot.browserDefaultEngine }) {
                guard let self else { return }
                if self.defaultEngine != engine { self.defaultEngine = engine }
            }
        }
    }
}
