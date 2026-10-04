import CmuxNextSettings
import Foundation
import Testing

/// `palette.scopes.<scope>.prefix`: user-assigned palette scope prefixes
/// (palette-scopes.md D-PS4). Missing keys keep the defaults; "none" turns
/// a prefix off; a bad value keeps the default with a diagnostic.
@Suite struct PaletteScopePrefixSettingsTests {
    func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func missingKeysAssignNothing() throws {
        let snapshot = try parse("{}")
        #expect(snapshot.paletteScopePrefixes.assigned.isEmpty)
        #expect(!snapshot.diagnostics.contains { $0.path.hasPrefix("palette.scopes") })
    }

    @Test func assignedCharactersAndNoneAreRead() throws {
        let snapshot = try parse(#"{"palette": {"scopes": {"workspaces": {"prefix": "@"}, "tabs": {"prefix": "none"}}}}"#)
        #expect(snapshot.paletteScopePrefixes.assigned["workspaces"] == .some("@"))
        #expect(snapshot.paletteScopePrefixes.assigned["tabs"] == .some(nil))
        #expect(snapshot.paletteScopePrefixes.assigned["commands"] == nil)
    }

    @Test func aLetterOrALongValueKeepsTheDefaultWithADiagnostic() throws {
        for value in [#""t""#, #""@@""#, "1", "true"] {
            let snapshot = try parse(#"{"palette": {"scopes": {"tabs": {"prefix": "# + value + "}}}}")
            #expect(snapshot.paletteScopePrefixes.assigned["tabs"] == nil, "\(value)")
            #expect(snapshot.diagnostics.contains { $0.path == "palette.scopes.tabs.prefix" }, "\(value)")
        }
    }

    /// The schema rows and their defaults are the palette's built-in prefixes
    /// (the palette's own table: PaletteScopeDescriptor.builtIns).
    @Test func schemaRowsMatchTheBuiltInDefaults() {
        let expected = ["tabs": "@", "workspaces": "#", "commands": ">", "settings": ",", "scopes": "?"]
        for (scope, prefix) in expected {
            let descriptor = SettingsSchema.descriptor(for: PaletteScopePrefixes.path(scope))
            #expect(descriptor?.defaultValue == .string(prefix), "\(scope)")
            #expect(SettingsSchema.agentSettableKeys.contains("palette.scopes.\(scope).prefix"))
        }
        #expect(Dictionary(uniqueKeysWithValues: PaletteScopePrefixes.defaults.map { ($0.scope, $0.prefix) }) == expected)
    }
}
