/// `agentPane.display.thinking.glyph` in cmux-next.json: a look's thinking dots, a
/// `cmux.particles/1` document (cmux-app-host js/ABI.md "Particles choreography"; Leo, 2026-11-19:
/// "i guess the particle systems could be an api as well... like the customizations thing?").
///
/// ```json
/// "agentPane": { "display": { "thinking": { "glyph": { "$schema": "cmux.particles/1", "particle": { "size": 3.3 }, "phases": { ... } } } } }
/// ```
///
/// The whole check is Rust's, the one validator (cmux-app-host `particles::validate`) that also checks
/// every scene's `choreography`: the daemon's settings owner (cmux-config `domain:particles_document`)
/// refuses an invalid document on every write, the CLI's and MCP's included, with its first bad path.
/// The app's own check here is only the shape the players need to start (an object of the schema
/// with a particle size and phases, under the size limit), so it never drops a document the owner
/// accepted, and the players read what they get defensively.
public nonisolated struct ThinkingGlyphSetting: Sendable {
    /// The key's path.
    public let configPath = AgentPaneDisplaySettingsSchema.thinkingGlyphPath
    /// The schema id a document names in `$schema`.
    public static let schema = "cmux.particles/1"
    /// The validator's limit on the compact document (particles.rs `MAX_DOCUMENT_BYTES`).
    public static let maxDocumentBytes = 32 * 1024

    public init() {}

    /// Whether `value` has the document's shape (the Settings write check).
    public static func accepts(_ value: JSONValue) -> Bool {
        guard let members = value.objectValue, members["$schema"]?.stringValue == schema,
              let particle = members["particle"]?.objectValue, (particle["size"]?.doubleValue ?? 0) > 0,
              let phases = members["phases"]?.objectValue, !phases.isEmpty
        else { return false }
        return value.compactText.utf8.count <= maxDocumentBytes
    }
}
