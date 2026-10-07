import Foundation
import Testing
@testable import CmuxNextApp

/// Every theme Ghostty can load, and the specs theme actions accept.
@MainActor @Suite struct ThemeCatalogTests {
    private func folder(_ names: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "cmux-themes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for name in names { try Data("background = #000000\n".utf8).write(to: url.appending(path: name)) }
        return url
    }

    @Test func listsResourceAndUserThemesSortedAndMerged() throws {
        let resources = try folder([])
        let themes = resources.appending(path: "themes")
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        for name in ["nord", "Zenburn", "Catppuccin Mocha"] { try Data().write(to: themes.appending(path: name)) }
        let config = try folder([])
        let user = config.appending(path: "ghostty/themes")
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        for name in ["My Theme", "Zenburn", ".DS_Store"] { try Data().write(to: user.appending(path: name)) }
        let names = ThemeCatalog.list(resources: resources.path, home: config, environment: ["XDG_CONFIG_HOME": config.path])
        #expect(names == ["Catppuccin Mocha", "My Theme", "nord", "Zenburn"])
    }

    @Test func pairsAndPathsOfKnownThemesAreAccepted() throws {
        let catalog = ThemeCatalog()
        // Before the list loads any well-formed spec passes.
        #expect(catalog.accepts("Anything"))
        #expect(!catalog.accepts("bad = value"))
    }
}
