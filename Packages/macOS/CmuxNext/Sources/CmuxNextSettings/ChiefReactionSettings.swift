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

    public init(canWake: Bool = true, harness: String = "", model: String = ChiefReactionSettings.defaultModel, prompt: String = "") {
        self.canWake = canWake
        self.harness = harness
        self.model = model
        self.prompt = prompt
    }

    public static let canWakePath = ["chief", "reactionsCanWake"]
    public static let harnessPath = ["chief", "reactionClassifier", "harness"]
    public static let modelPath = ["chief", "reactionClassifier", "model"]
    public static let promptPath = ["chief", "reactionClassifier", "prompt"]
    /// Claude Haiku, the compactor's model too (Lawrence 2026-10-21: "use claude haiku as the cheap model by default").
    public static let defaultModel = "claude-haiku-5-5"
    public static let fallback = ChiefReactionSettings()
    /// Every key, for the agent policy (a Chief may configure its own reactions).
    public static let keys: Set<String> = Set([canWakePath, harnessPath, modelPath, promptPath].map { $0.joined(separator: ".") })

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
