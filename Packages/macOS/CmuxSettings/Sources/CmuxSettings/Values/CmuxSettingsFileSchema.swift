/// The schema identity of the cmux settings file (`cmux.json`): the version the
/// app writes and accepts, the canonical `$schema` URL embedded in generated
/// files, and the legacy `$schema` URL rewritten to the canonical one when an
/// older `settings.json` is migrated.
///
/// A pure value type rather than a static-constant namespace: ``current`` is the
/// single canonical instance the app reads, so the schema's identity is a value
/// that can be compared, passed, and (in tests) substituted, instead of a bag of
/// `static let`s on the settings-file store.
public struct CmuxSettingsFileSchema: Sendable, Equatable {
    /// The schema version the app writes into generated settings files and treats
    /// as the highest version it fully understands.
    public let version: Int

    /// The canonical `$schema` URL embedded in files the app generates.
    public let schemaURLString: String

    /// The legacy `$schema` URL rewritten to ``schemaURLString`` when an older
    /// `settings.json` is migrated into the primary template.
    public let legacySchemaURLString: String

    /// Creates a schema identity. Use ``current`` for the app's live schema.
    public init(version: Int, schemaURLString: String, legacySchemaURLString: String) {
        self.version = version
        self.schemaURLString = schemaURLString
        self.legacySchemaURLString = legacySchemaURLString
    }

    /// The schema the running app reads and writes.
    public static let current = CmuxSettingsFileSchema(
        version: 1,
        schemaURLString: "https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux.schema.json",
        legacySchemaURLString: "https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux-settings.schema.json"
    )
}
