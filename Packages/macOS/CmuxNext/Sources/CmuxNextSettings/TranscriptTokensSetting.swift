/// `agentPane.display.transcriptTokens` in cmux-next.json or a theme file: per-token overrides of the
/// transcript look (`agentPane.display.transcriptLook`), token name to value
/// (docs/cmux-next/transcript-customization.md):
///
/// ```json
/// "agentPane.display.transcriptTokens": { "userMessage.radius": 20, "timestamps": "always" }
/// ```
///
/// The token table is schemas/transcript-look/transcript-look.json. cmux-config (transcript_look.rs)
/// checks each token's name and range on `cmux settings set` and `cmux theme check`; the chat page
/// drops a value it refuses. Here, the write check is the shape only, so the app never refuses a
/// token a newer page knows.
public nonisolated struct TranscriptTokensSetting: Sendable {
    public static let configPath = AgentPaneDisplaySettingsSchema.transcriptTokensPath

    /// The most tokens one object holds; the table has fewer than 64.
    public static let limit = 256

    /// Whether `value` is an object of token names to strings or finite numbers.
    public static func accepts(_ value: JSONValue) -> Bool {
        guard case .object(let members) = value, members.count <= limit else { return false }
        return members.allSatisfy { name, token in
            guard !name.isEmpty else { return false }
            if token.stringValue != nil { return true }
            return token.doubleValue?.isFinite ?? false
        }
    }
}
