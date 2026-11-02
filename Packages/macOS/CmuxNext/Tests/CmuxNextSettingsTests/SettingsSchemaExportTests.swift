@testable import CmuxNextSettings
import Foundation
import Testing

/// `schemas/settings/settings-schema.json` is what the daemon's config actor
/// validates against and what the web Settings page renders, so it must
/// match `SettingsSchema.all` exactly, and every text in it must resolve to
/// one string catalog key (the page localizes from the same xcstrings).
@Suite struct SettingsSchemaExportTests {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func catalog() throws -> Set<String> {
        let url = repoRoot.appending(path: "Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Localizable.xcstrings")
        return try SettingsSchemaExport().catalogKeys(xcstrings: Data(contentsOf: url))
    }

    /// `CMUX_UPDATE_ACTION_SURFACES=1 swift test --filter SettingsSchemaExportTests` rewrites it.
    /// The generated files job of cmux-next.yml runs that export and fails when the committed copy
    /// differs; no committed stamp of the sources stands in for it (Leo 2026-10-21).
    @Test func exportIsFresh() throws {
        let url = Self.repoRoot.appending(path: "schemas/settings/settings-schema.json")
        let current = try SettingsSchemaExport().json(catalog: Self.catalog())
        if ProcessInfo.processInfo.environment["CMUX_UPDATE_ACTION_SURFACES"] == "1" {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try current.write(to: url, atomically: true, encoding: .utf8)
        }
        let stored = try String(contentsOf: url, encoding: .utf8)
        #expect(stored == current, "settings-schema.json is stale; rerun with CMUX_UPDATE_ACTION_SURFACES=1")
    }

    /// Every row carries values Swift accepts or refuses, so another validator
    /// has something to agree with; portable kinds carry both.
    @Test func everyRowHasConformanceSamples() throws {
        for descriptor in SettingsSchema.all {
            let samples = SettingsSchemaSamples.samples(for: descriptor)
            let accepted = samples.accept.filter(descriptor.accepts)
            let refused = samples.refuse.filter { !descriptor.accepts($0) }
            #expect(refused.count == samples.refuse.count, "\(descriptor.id): a refuse sample is accepted")
            #expect(accepted.count == samples.accept.count, "\(descriptor.id): an accept sample is refused")
            #expect(!refused.isEmpty, "\(descriptor.id) has no refused sample")
        }
    }

    /// Every schema text names its catalog key; only product names (choice
    /// titles that are not translated) have none.
    @Test func everyTextHasACatalogKey() {
        for descriptor in SettingsSchema.all {
            let keys = descriptor.textKeys
            #expect(keys.group != nil && keys.title != nil, "\(descriptor.id): group or title has no key")
            #expect((descriptor.help == nil) == (keys.help == nil), "\(descriptor.id): help has no key")
            #expect((descriptor.summary == nil) == (keys.summary == nil), "\(descriptor.id): summary has no key")
            #expect((descriptor.defaultLabel == nil) == (keys.defaultLabel == nil), "\(descriptor.id): default label has no key")
        }
    }

    /// Every key is in exactly one agent table, and the tables name only keys.
    @Test func everyKeyHasAnExplicitAgentPolicy() {
        let ids = Set(SettingsSchema.all.map(\.id))
        let refused = Set(SettingsSchema.agentRefusedKeys.keys)
        #expect(SettingsSchema.agentSettableKeys.isDisjoint(with: refused), "a key is both settable and refused")
        let missing = ids.subtracting(SettingsSchema.agentSettableKeys).subtracting(refused)
        #expect(missing.isEmpty, "no agent policy for: \(missing.sorted())")
        let unknown = SettingsSchema.agentSettableKeys.union(refused).subtracting(ids)
        #expect(unknown.isEmpty, "agent policy names unknown keys: \(unknown.sorted())")
        #expect(SettingsSchema.agentSettableKeys.contains("appearance.backgroundOpacity"))
        #expect(SettingsSchema.agentSettableKeys.contains("appearance.backgroundBlur"))
    }

    /// The checked-in schema is the descriptor registry consumed by the
    /// daemon, CLI and MCP clients. Every row must carry the same surface
    /// declaration that the native Settings page and palette use; otherwise
    /// a new descriptor can silently become provider-dependent.
    @Test func everyRowDeclaresSurfaceParity() throws {
        let data = try SettingsSchemaExport().json(catalog: Self.catalog()).data(using: .utf8)!
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try #require(root["rows"] as? [[String: Any]])
        let rowsByKey = Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            (row["key"] as? String).map { ($0, row) }
        })
        #expect(rowsByKey.count == SettingsSchema.all.count)
        for descriptor in SettingsSchema.all {
            let plan = descriptor.surfacePlan
            let row = try #require(rowsByKey[descriptor.id], Comment(rawValue: descriptor.id))
            let surfaces = try #require(row["surfaces"] as? [String: Any], Comment(rawValue: descriptor.id))
            #expect(Set(surfaces.keys) == Set(["palette", "cli", "mcp", "socket"]), Comment(rawValue: descriptor.id))
            for (name, expected) in [("cli", plan.cli), ("mcp", plan.mcp), ("socket", plan.socket)] {
                let surface = try #require(surfaces[name] as? [String: Any], Comment(rawValue: "\(descriptor.id): \(name)"))
                #expect(surface["operations"] as? [String] == expected.operations, Comment(rawValue: "\(descriptor.id): \(name)"))
                #expect(surface["aliases"] as? [String] == expected.aliases, Comment(rawValue: "\(descriptor.id): \(name)"))
                #expect(surface["app_operations"] as? [String] == expected.appOperations, Comment(rawValue: "\(descriptor.id): \(name)"))
                #expect(surface["app_aliases"] as? [String] == expected.appAliases, Comment(rawValue: "\(descriptor.id): \(name)"))
                #expect(surface["offered"] as? Bool == expected.offered, Comment(rawValue: "\(descriptor.id): \(name)"))
            }
            let palette = try #require(surfaces["palette"] as? [String: Any], Comment(rawValue: "\(descriptor.id): palette"))
            #expect(palette["offered"] as? Bool == plan.palette.offered, Comment(rawValue: descriptor.id))
            #expect(palette["operations"] as? [String] == plan.palette.operations, Comment(rawValue: descriptor.id))
            #expect(palette["row"] as? String == plan.palette.row, Comment(rawValue: descriptor.id))
            #expect(palette["editor"] as? String == plan.palette.editor, Comment(rawValue: descriptor.id))
        }
    }

    /// A key missing from the catalog fails the export.
    @Test func missingKeyFailsTheExport() {
        #expect(throws: SettingsSchemaExport.MissingKeys.self) { try SettingsSchemaExport().json(catalog: []) }
    }
}
