import CmuxChief
import CmuxSettings
import Foundation

/// Which agent CLI answers as Chief, with which model and effort: the cmux
/// settings `chief.harness`, `chief.model`, `chief.effort` and
/// `chief.dangerouslySkipPermissions`.
///
/// Empty values mean the default (Claude Code; the harness's default model
/// and effort). Read and written through ``ChiefSettingsAccess``.
struct ChiefEngineSettings: Equatable, Sendable {
    /// The agent CLI (`claude` or `codex`); empty for the default.
    var harness: String
    /// The model id; empty for the harness's default.
    var model: String
    /// The reasoning effort; empty for the harness's default.
    var effort: String
    /// Whether the harness may bypass permission prompts. Off by default.
    var dangerouslySkipPermissions: Bool

    /// The harness that runs: an empty or unknown value is Claude Code.
    var resolvedHarness: CmuxChief.ChiefHarness { CmuxChief.ChiefHarness(rawValue: harness.lowercased()) ?? .claude }

    /// The model that runs.
    var resolvedModel: String { model.isEmpty ? resolvedHarness.defaultModel : model }

    /// Values trimmed; an unknown harness becomes the default.
    var normalized: ChiefEngineSettings {
        var copy = self
        copy.harness = copy.harness.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if CmuxChief.ChiefHarness(rawValue: copy.harness) == nil { copy.harness = "" }
        copy.model = copy.model.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.effort = copy.effort.trimmingCharacters(in: .whitespacesAndNewlines)
        // The catalog is the only safe source for explicit effort flags. A
        // custom or newly introduced model has an unknown capability set, so
        // keep it on the model's own default rather than carrying a stale
        // value from the previously selected model into the next turn.
        let offered = copy.resolvedHarness.efforts(for: copy.resolvedModel)
        if !copy.effort.isEmpty, !offered.contains(where: { $0.id == copy.effort }) {
            copy.effort = ""
        }
        return copy
    }
}

/// Reads and writes the Chief engine settings: the `chief.*` keys of
/// `CmuxSettings`' ``ChiefCatalogSection``, mirrored to `UserDefaults` like
/// every `DefaultsKey`, so cmux.json, Settings and the Chief settings panel
/// reach the same values. Changes are observed through
/// `UserDefaults.didChangeNotification` (no polling).
struct ChiefSettingsAccess {
    static let harnessKey = ChiefCatalogSection().harness.userDefaultsKey
    static let modelKey = ChiefCatalogSection().model.userDefaultsKey
    static let effortKey = ChiefCatalogSection().effort.userDefaultsKey
    static let dangerouslySkipPermissionsKey = ChiefCatalogSection().dangerouslySkipPermissions.userDefaultsKey

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The current settings, normalized.
    var current: ChiefEngineSettings {
        ChiefEngineSettings(harness: defaults.string(forKey: Self.harnessKey) ?? "",
                            model: defaults.string(forKey: Self.modelKey) ?? "",
                            effort: defaults.string(forKey: Self.effortKey) ?? "",
                            dangerouslySkipPermissions: defaults.bool(forKey: Self.dangerouslySkipPermissionsKey)).normalized
    }

    /// Writes `settings`; an empty value removes its key (the default).
    func write(_ settings: ChiefEngineSettings) {
        let value = settings.normalized
        for (key, text) in [(Self.harnessKey, value.harness), (Self.modelKey, value.model), (Self.effortKey, value.effort)] {
            if text.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(text, forKey: key) }
        }
        if value.dangerouslySkipPermissions {
            defaults.set(true, forKey: Self.dangerouslySkipPermissionsKey)
        } else {
            defaults.removeObject(forKey: Self.dangerouslySkipPermissionsKey)
        }
    }
}
