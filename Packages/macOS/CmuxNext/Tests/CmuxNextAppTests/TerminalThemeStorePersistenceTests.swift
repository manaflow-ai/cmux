import Foundation
import Testing
@testable import CmuxNextApp

/// `terminal-themes.json` (per-terminal themes on a home daemon without
/// personal terminal state) keeps every saved theme across launches: a
/// theme set before the file loaded does not replace the file, and a file
/// this build cannot fully read (a newer format, a damaged write) is left
/// alone rather than rewritten without the entries it skipped.
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

    @Test(arguments: [
        #"{"local:tab_a": "Catppuccin Mocha", "local:tab_b": {"light": "Rose Pine Dawn", "dark": "Rose Pine"}}"#,
        #"{"local:tab_a": "Catppuccin Mocha", "#,
    ])
    func aFileThisBuildCannotReadIsNotRewritten(_ text: String) async throws {
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
}
