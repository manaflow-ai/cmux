// The paths and defaults are generated from schemas/settings/source/chief-reactions.json
// (Schema/SettingsSchema+ChiefReactions.generated.swift).

/// `chief.reactionsCanWake` and `chief.reactionClassifier.*` in cmux.json (Lawrence 2026-10-21, a416): a
/// tapback the person puts on a Chief message is a note, and a cheap model decides first whether it starts
/// a turn (a ❓ on a question does, a 👍 on a status line does not). These are the person's values; each
/// Chief may override them in its engine.json (`chief engine set --classifier-model …`, the Chief Settings
/// card). The Chief host reads the keys at each decision, so a change applies at once.
public nonisolated struct ChiefReactionSettings: Sendable, Hashable {
    /// Whether a reaction may start a turn at all; off, every reaction is only a note.
    public var canWake: Bool
    /// The acpmux harness the classifier runs on; empty: the host's Claude route.
    public var harness: String
    /// The classifier's model; Claude Haiku by default (cheap and fast).
    public var model: String
    /// The classifier's instructions; empty: the host's built-in prompt.
    public var prompt: String

    public init(canWake: Bool = ChiefReactionSettings.canWakeDefault, harness: String = ChiefReactionSettings.harnessDefault,
                model: String = ChiefReactionSettings.modelDefault, prompt: String = ChiefReactionSettings.promptDefault) {
        self.canWake = canWake
        self.harness = harness
        self.model = model
        self.prompt = prompt
    }

    public static let fallback = ChiefReactionSettings()

    /// The values in `root`; a value of the wrong type is the default plus a diagnostic.
    static func parse(_ root: JSONValue) -> (ChiefReactionSettings, [SettingsDiagnostic]) {
        var settings = fallback
        var diagnostics: [SettingsDiagnostic] = []
        func wrong(_ path: [String], _ expected: String) {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path.joined(separator: "."), message: "expected " + expected))
        }
        if let value = root.value(at: canWakePath) {
            if let on = value.boolValue { settings.canWake = on } else { wrong(canWakePath, "true or false") }
        }
        for (path, keyPath) in [(harnessPath, \ChiefReactionSettings.harness), (modelPath, \.model), (promptPath, \.prompt)] {
            guard let value = root.value(at: path) else { continue }
            if let text = value.stringValue { settings[keyPath: keyPath] = text } else { wrong(path, "a string") }
        }
        return (settings, diagnostics)
    }
}
