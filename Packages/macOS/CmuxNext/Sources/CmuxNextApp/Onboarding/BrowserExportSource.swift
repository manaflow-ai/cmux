import Foundation

/// A browser whose export steps Import from Another Browser… shows, one row
/// of `browser-export-steps.json`. The steps' text follows `family`; a
/// Chromium browser's rows name the pages it exports from.
nonisolated struct BrowserExportSource: Decodable, Equatable, Sendable {
    enum Family: String, Decodable, Sendable {
        case chromium
        case firefox
        case safari
    }

    let id: String
    /// A product name, not translated.
    let name: String
    let family: Family
    /// The page that exports passwords (Chromium browsers).
    let passwords: String?
    /// The page that exports bookmarks (Chromium browsers).
    let bookmarks: String?

    /// The bundled rows, in the order the picker lists them; empty when the file is missing.
    static let all: [BrowserExportSource] = {
        struct File: Decodable { let browsers: [BrowserExportSource] }
        guard let url = Bundle.module.url(forResource: "browser-export-steps", withExtension: "json"),
              let data = try? Data(contentsOf: url), // concurrency-allow: a small bundled resource, read once
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.browsers
    }()
}
