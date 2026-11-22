import Foundation
import Testing
@testable import CmuxNextApp

/// `terminal-themes.json` (per-terminal themes on a home daemon without
/// personal terminal state) keeps every saved theme across launches: a
/// theme set before the file loaded does not replace the file, and a file
/// this build cannot fully read (a newer format, a damaged write) is left
/// alone rather than rewritten without the entries it skipped, and its
/// entries are not migrated to personal state again on every launch. A
/// file that is not JSON at all is moved aside and saving goes on.
@MainActor @Suite struct TerminalThemeStorePersistenceTests {
    func makeFile(_ text: String) throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-terminal-themes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "terminal-themes.json")
        try Data(text.utf8).write(to: url)
        return (url, directory)
    }

    func saved(_ url: URL) throws -> [String: String] {
        try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    }

    @Test func aThemeSetBeforeTheFileLoadsKeepsTheSavedOnes() async throws {
        let (url, directory) = try makeFile(#"{"local:tab_a": "Catppuccin Mocha"}"#)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TerminalThemeStore(url: url)
        store.set("Nord", for: "local:tab_b")
        await store.flush()
        await store.load()
        await store.flush()
        #expect(store.theme(for: "local:tab_a") == "Catppuccin Mocha")
        #expect(try saved(url) == ["local:tab_a": "Catppuccin Mocha", "local:tab_b": "Nord"])

        // The next launch reads both.
        let next = TerminalThemeStore(url: url)
        await next.load()
        #expect(next.themes == ["local:tab_a": "Catppuccin Mocha", "local:tab_b": "Nord"])
    }

    static let newerFormat = #"{"local:tab_a": "Catppuccin Mocha", "local:tab_b": {"light": "Rose Pine Dawn", "dark": "Rose Pine"}}"#

    @Test func aNewerFormatFileIsNotRewritten() async throws {
        let text = Self.newerFormat
        let (url, directory) = try makeFile(text)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TerminalThemeStore(url: url)
        await store.load()
        store.set("Nord", for: "local:tab_c")
        store.prune(machine: "local", liveTabs: ["tab_c"])
        await store.flush()
        #expect(try String(contentsOf: url, encoding: .utf8) == text)
        // This launch still uses the theme it set.
        #expect(store.theme(for: "local:tab_c") == "Nord")
    }

    @Test func entriesOfANewerFormatThatAreReadableStillApply() async throws {
        let (url, directory) = try makeFile(#"{"local:tab_a": "Catppuccin Mocha", "local:tab_b": {"light": "Rose Pine Dawn"}}"#)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TerminalThemeStore(url: url)
        await store.load()
        #expect(store.theme(for: "local:tab_a") == "Catppuccin Mocha")
    }

    /// A newer build's file is kept, so a migration that clears its entries
    /// only clears them in memory: the next launch must not migrate them
    /// again (over picks made in personal state since).
    @Test func aKeptFileIsNotMigratedAgainOnTheNextLaunch() async throws {
        let (url, directory) = try makeFile(Self.newerFormat)
        defer { try? FileManager.default.removeItem(at: directory) }
        for launch in 1...2 {
            let store = TerminalThemeStore(url: url)
            await store.load()
            // What `ThemeCoordinator.migrateTerminalThemes` does with each entry.
            let migrated = store.migratableThemes
            for key in migrated.keys { store.set(nil, for: key) }
            await store.flush()
            if launch == 2 { #expect(migrated.isEmpty, "migrated again: \(migrated)") }
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == Self.newerFormat)
    }

    /// A file that is not JSON at all (a damaged write) is moved aside, not
    /// left to block saving: themes set afterwards persist.
    @Test func aDamagedFileIsMovedAsideAndSavingGoesOn() async throws {
        let damaged = #"{"local:tab_a": "Catppuccin Mocha", "#
        let (url, directory) = try makeFile(damaged)
        defer { try? FileManager.default.removeItem(at: directory) }
        // An earlier damaged file already moved aside stays as it is.
        let earlier = url.appendingPathExtension("corrupt")
        try Data("earlier".utf8).write(to: earlier)
        let store = TerminalThemeStore(url: url)
        await store.load()
        store.set("Nord", for: "local:tab_c")
        await store.flush()
        #expect(try saved(url) == ["local:tab_c": "Nord"])
        #expect(try String(contentsOf: earlier, encoding: .utf8) == "earlier")
        let aside = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("terminal-themes.json.corrupt") && $0 != earlier.lastPathComponent }
        #expect(aside.count == 1)
        if let name = aside.first {
            #expect(try String(contentsOf: directory.appending(path: name), encoding: .utf8) == damaged)
        }
    }
}
