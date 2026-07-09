public import Foundation

/// `UserDefaults`-backed reader for the tmux pane-overlay experiment flags.
///
/// Holds the two byte-sensitive defaults keys (`tmuxOverlayExperimentEnabled`,
/// `tmuxOverlayExperimentTarget`) and resolves the active
/// ``TmuxOverlayExperimentTarget`` from them. Byte-faithful lift of the
/// app-target all-static reader; the keys and `Type.method(...)` call spelling
/// are consumed verbatim by ContentView/TerminalPanel/WorkspaceContentView and
/// the unit tests, so converting it to an injected instance reader is
/// behavior-affecting and is deferred to a dedicated modernization PR.
// lint:allow namespace-type — faithful lift; instance conversion is a deferred,
// behavior-affecting modernization (see DocC above).
public struct TmuxOverlayExperimentSettings {
    /// Defaults key for whether the experiment is enabled.
    public static let enabledKey = "tmuxOverlayExperimentEnabled"
    /// Defaults key for the persisted ``TmuxOverlayExperimentTarget`` raw value.
    public static let targetKey = "tmuxOverlayExperimentTarget"
    /// Default enabled state when the key is absent.
    public static let defaultEnabled = false
    /// Default target when enabled but no valid raw value is stored.
    public static let defaultTarget: TmuxOverlayExperimentTarget = .surface

    /// Reads the enabled flag, falling back to ``defaultEnabled``.
    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }

    /// Resolves the active target from the stored enabled flag and raw value.
    public static func target(defaults: UserDefaults = .standard) -> TmuxOverlayExperimentTarget {
        target(
            enabled: isEnabled(defaults: defaults),
            rawValue: defaults.string(forKey: targetKey)
        )
    }

    /// Pure resolution: `surface` when disabled, the decoded target when a valid
    /// raw value is present, else ``defaultTarget``.
    public static func target(enabled: Bool, rawValue: String?) -> TmuxOverlayExperimentTarget {
        guard enabled else { return .surface }
        guard let rawValue,
              let target = TmuxOverlayExperimentTarget(rawValue: rawValue) else {
            return defaultTarget
        }
        return target
    }
}
