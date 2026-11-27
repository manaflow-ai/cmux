import Foundation
import Testing
@testable import CmuxTerminalImport

@Suite("Detecting and loading installed terminals")
struct TerminalImporterTests {
    let fixtures = TestFixtures()

    /// A reader that maps a fake home directory onto fixture files.
    struct MappedReader: TerminalConfigFileReading {
        var files: [String: URL]
        var directories: [String: [URL]] = [:]

        func contents(of url: URL) -> String? {
            files[url.path].flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        }

        func files(in url: URL) -> [URL] {
            directories[url.path] ?? []
        }
    }

    func importer(files: [String: URL] = [:], directories: [String: [URL]] = [:], domains: [String: URL] = [:]) -> TerminalImporter {
        TerminalImporter(
            homeDirectory: URL(fileURLWithPath: "/Users/test", isDirectory: true),
            environment: [:],
            preferences: StubPreferences(domains: domains),
            files: MappedReader(files: files, directories: directories)
        )
    }

    @Test("lists only the terminals that have settings")
    func detect() {
        let warpTheme = URL(fileURLWithPath: "/Users/test/.warp/themes/solarized.yaml")
        let found = importer(
            files: [
                "/Users/test/.config/kitty/kitty.conf": fixtures.url("kitty/kitty.conf"),
                "/Users/test/.config/ghostty/config": fixtures.url("kitty/current-theme.conf"),
                warpTheme.path: fixtures.url("warp/solarized.yaml"),
            ],
            directories: ["/Users/test/.warp/themes": [warpTheme]],
            domains: [
                "com.googlecode.iterm2": fixtures.url("iterm2.plist"),
                "com.apple.Terminal": fixtures.url("terminal-app-builtin.plist"),
            ]
        ).detect()

        #expect(found.map(\.source) == [.iTerm2, .kitty, .warp, .ghostty])
        #expect(found[0].detail == "default profile \"Work\"")
        #expect(found[1].detail == "~/.config/kitty/kitty.conf")
        #expect(found[2].configURL == warpTheme)
    }

    @Test("loads a file source from its detected path, following includes")
    func loadKitty() throws {
        // Includes resolve next to the real fixture file, so map the directory.
        let reader = DiskTerminalConfigFileReader()
        let importer = TerminalImporter(
            homeDirectory: URL(fileURLWithPath: "/Users/test", isDirectory: true),
            environment: ["KITTY_CONFIG_DIRECTORY": fixtures.url("kitty").path],
            preferences: StubPreferences(),
            files: reader
        )
        let settings = try importer.load(.kitty)
        #expect(settings.colors.palette.count == 16)
    }

    @Test("Ghostty, built-in Terminal profiles and several Warp themes explain themselves")
    func errors() {
        let themes = [
            URL(fileURLWithPath: "/Users/test/.warp/themes/a.yaml"),
            URL(fileURLWithPath: "/Users/test/.warp/themes/b.yaml"),
        ]
        let importer = importer(
            directories: ["/Users/test/.warp/themes": themes],
            domains: ["com.apple.Terminal": fixtures.url("terminal-app-builtin.plist")]
        )
        #expect(throws: TerminalImportError.ghosttyAlreadyLoaded) { try importer.load(.ghostty) }
        #expect(throws: TerminalImportError.builtInTerminalProfile("Basic")) { try importer.load(.terminalApp) }
        #expect(throws: TerminalImportError.warpThemeChoiceNeeded(themes)) { try importer.load(.warp) }
        #expect(throws: TerminalImportError.notFound(.alacritty)) { try importer.load(.alacritty) }
    }

    @Test("source names accept common spellings")
    func sourceNames() {
        #expect(TerminalImportSource(argument: "iTerm") == .iTerm2)
        #expect(TerminalImportSource(argument: "Terminal.app") == .terminalApp)
        #expect(TerminalImportSource(argument: "WezTerm") == .wezTerm)
        #expect(TerminalImportSource(argument: "hyper") == nil)
    }
}
