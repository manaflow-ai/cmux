import CmuxNextCompat
import Foundation

/// A browser whose export steps Import from Another Browser… shows, one row
/// of `browser-export-steps.json`. The steps' text follows `family`; a Chromium browser's rows
/// name the pages it exports from. Password managers (1Password, Bitwarden) export passwords only.
nonisolated struct BrowserExportSource: Decodable, Equatable, Sendable {
    enum Family: String, Decodable, Sendable {
        case chromium
        case firefox
        case safari
        case onePassword = "1password"
        case bitwarden
    }

    let id: String
    /// A product name, not translated.
    let name: String
    let family: Family
    /// The page that exports passwords (Chromium browsers).
    let passwords: String?
    /// The page that exports bookmarks (Chromium browsers); nil when it has no bookmarks export (Arc).
    let bookmarks: String?
    /// Where its history exports (Chrome: Google Takeout).
    let history: String?

    /// The bundled rows, in the order the picker lists them; empty when the file is missing. A file read:
    /// the picker awaits it on the files lane (``BrowserFileImport``), never a static initializer that
    /// blocks whichever thread reads it first (once-blocking).
    static func loadBundled() -> [BrowserExportSource] {
        struct File: Decodable { let browsers: [BrowserExportSource] }
        guard let url = Bundle.module.url(forResource: "browser-export-steps", withExtension: "json"),
              let data = try? Data(blockingContentsOf: url),
              let file = try? JSONDecoder().blockingDecode(File.self, from: data) else { return [] }
        return file.browsers
    }
}
