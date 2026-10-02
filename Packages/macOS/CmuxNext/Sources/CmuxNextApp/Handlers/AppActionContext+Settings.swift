import CmuxNextActions
import CmuxNextSettings
import os

/// The palette's one write path for cmux.json settings: every handler that
/// writes a key `SettingsSchema` lists goes through
/// `SettingsController.setSetting(at:to:)`, the validated write the
/// Settings window uses, so a managed key or a value the schema refuses is
/// refused the same way from every entrypoint.
extension AppActionContext {
    private static let settingsLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.actions")

    /// Writes `edits` in order, after the handler applied the live value.
    /// The task is tracked, so `action.run` answers once the file has it.
    /// A failure is logged; with `reloadOnFailure` the settings reload so
    /// the file and the managed layers win over the live value again.
    func writeSettings(_ label: String, _ edits: [([String], JSONValue?)], reloadOnFailure: Bool = false) {
        guard let settings = services.settings else { return }
        registry.track(Task { @MainActor in
            do {
                for (path, value) in edits { try await settings.setSetting(at: path, to: value) }
                return nil
            } catch {
                Self.settingsLogger.error("\(label, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                if reloadOnFailure { await settings.reload() }
                return ActionWorkFailure(String(describing: error))
            }
        })
    }

    /// `writeSettings` for one key; nil removes it (its default applies).
    func writeSetting(_ label: String, _ path: [String], _ value: JSONValue?, reloadOnFailure: Bool = false) {
        writeSettings(label, [(path, value)], reloadOnFailure: reloadOnFailure)
    }
}
