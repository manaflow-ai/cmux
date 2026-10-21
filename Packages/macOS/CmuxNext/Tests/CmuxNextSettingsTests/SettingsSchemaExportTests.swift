@testable import CmuxNextSettings
import CryptoKit
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

    /// The exporter's inputs, for the freshness stamp. The export runs code
    /// compiled from these files and reads the catalog among them; the two
    /// exporter tests decide which files are written and how. Keep in step
    /// with `settings_source_stamp` in scripts/ci/defaults_guard.py, which
    /// recomputes the stamp without a Swift build.
    static let sourceDirectory = "Packages/macOS/CmuxNext/Sources/CmuxNextSettings"
    static let sourceExtensions: Set<String> = ["swift", "xcstrings"]
    static let exporterFiles = [
        "Packages/macOS/CmuxNext/Tests/CmuxNextSettingsTests/ManagedPreferencesManifestTests.swift",
        "Packages/macOS/CmuxNext/Tests/CmuxNextSettingsTests/SettingsSchemaExportTests.swift",
    ]

    struct SymbolicLinkInSources: Error, CustomStringConvertible {
        let path: String
        var description: String { "\(path) is a symbolic link; the settings export stamp reads no links" }
    }

    /// One `sha256  path` entry per input (lowercase hex of the file's bytes,
    /// two spaces, the repository-relative path) in UTF-8 path order, a blank
    /// line between entries and a newline at the end. An entry per file, apart,
    /// means two pull requests that edit different sources change lines git
    /// merges cleanly, and the merged stamp is the merged sources' (#21946).
    static func sourceStamp() throws -> String {
        let files = FileManager.default
        var paths = exporterFiles
        let directory = repoRoot.appending(path: sourceDirectory).path
        for sub in try files.subpathsOfDirectory(atPath: directory) {
            let path = "\(sourceDirectory)/\(sub)"
            let type = try files.attributesOfItem(atPath: repoRoot.appending(path: path).path)[.type] as? FileAttributeType
            if type == .typeSymbolicLink { throw SymbolicLinkInSources(path: path) }
            if type == .typeRegular, sourceExtensions.contains((sub as NSString).pathExtension) { paths.append(path) }
        }
        var entries: [String] = []
        for path in paths.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }) {
            if (try files.attributesOfItem(atPath: repoRoot.appending(path: path).path)[.type] as? FileAttributeType) == .typeSymbolicLink {
                throw SymbolicLinkInSources(path: path)
            }
            let digest = SHA256.hash(data: try Data(contentsOf: repoRoot.appending(path: path)))
            entries.append(digest.map { String(format: "%02x", $0) }.joined() + "  " + path)
        }
        return entries.joined(separator: "\n\n") + "\n"
    }

    /// `CMUX_UPDATE_ACTION_SURFACES=1 swift test --filter SettingsSchemaExportTests` rewrites it,
    /// and `schemas/settings-export/settings-schema.sources.sha256`, the digests of the sources it was
    /// exported from: `defaults_guard.py check-fresh` recomputes them and fails when the sources
    /// moved without a re-export (e190c402850c landed a schema exported before a merge). The stamp is
    /// outside schemas/settings, a web bundle input, so a source-only edit does not rebuild the bundles.
    @Test func exportIsFresh() throws {
        let url = Self.repoRoot.appending(path: "schemas/settings/settings-schema.json")
        let stampURL = Self.repoRoot.appending(path: "schemas/settings-export/settings-schema.sources.sha256")
        let current = try SettingsSchemaExport().json(catalog: Self.catalog())
        let currentStamp = try Self.sourceStamp()
        if ProcessInfo.processInfo.environment["CMUX_UPDATE_ACTION_SURFACES"] == "1" {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try current.write(to: url, atomically: true, encoding: .utf8)
            try currentStamp.write(to: stampURL, atomically: true, encoding: .utf8)
        }
        let stored = try String(contentsOf: url, encoding: .utf8)
        #expect(stored == current, "settings-schema.json is stale; rerun with CMUX_UPDATE_ACTION_SURFACES=1")
        let storedStamp = try? String(contentsOf: stampURL, encoding: .utf8)
        #expect(storedStamp == currentStamp, "settings-schema.sources.sha256 is stale; rerun with CMUX_UPDATE_ACTION_SURFACES=1")
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

    /// A key missing from the catalog fails the export.
    @Test func missingKeyFailsTheExport() {
        #expect(throws: SettingsSchemaExport.MissingKeys.self) { try SettingsSchemaExport().json(catalog: []) }
    }
}
