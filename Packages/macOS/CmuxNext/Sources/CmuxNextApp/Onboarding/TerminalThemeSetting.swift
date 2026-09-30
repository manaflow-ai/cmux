import CmuxNextSettings
import CmuxNextTerminal
import Observation

/// `appearance.theme` in cmux.json: a Ghostty theme for cmux only (the
/// onboarding theme step writes it). Applied as `GhosttyRuntime.themeOverride`
/// and a config reload, so terminals and chrome follow it live.
@MainActor
final class TerminalThemeSetting {
    static let path = ["appearance", "theme"]
    private var applied: String??
    private var observation: Task<Void, Never>?

    func follow(_ settings: SettingsController) {
        observation = Task { [weak self] in
            for await snapshot in Observations({ settings.snapshot }) {
                self?.apply(snapshot.root.value(at: Self.path)?.stringValue)
            }
        }
    }

    private func apply(_ theme: String?) {
        let value = theme.flatMap { $0.isEmpty ? nil : $0 }
        guard applied != .some(value) else { return }
        let first = applied == nil
        applied = .some(value)
        GhosttyRuntime.themeOverride = value
        // At launch with no override the config already loaded as is.
        if !(first && value == nil) { GhosttyRuntime.shared.reloadConfig() }
    }
}
