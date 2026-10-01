import Foundation
@testable import CmuxTerminalImport

/// Locates fixture files and builds test doubles for the importer's seams.
struct TestFixtures {
    let root: URL

    init() {
        guard let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil) else {
            fatalError("Fixtures folder missing from the test bundle")
        }
        root = url
    }

    func url(_ relative: String) -> URL {
        root.appendingPathComponent(relative, isDirectory: false)
    }

    func text(_ relative: String) throws -> String {
        try String(contentsOf: url(relative), encoding: .utf8)
    }

    func plist(_ relative: String) throws -> [String: Any] {
        let data = try Data(contentsOf: url(relative))
        return try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] ?? [:]
    }
}

/// Resolves a fixed set of PostScript names; everything else counts as not installed.
struct StubFontResolver: FontFamilyResolving {
    var families: [String: String] = [:]

    func familyName(forPostScriptName postScriptName: String) -> String? {
        families[postScriptName]
    }
}

/// Serves preferences domains from fixture plists.
struct StubPreferences: TerminalPreferencesReading {
    var domains: [String: URL] = [:]

    func preferences(forDomain domain: String) -> [String: Any]? {
        guard let url = domains[domain], let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}
