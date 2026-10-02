import Testing
@testable import CmuxNextDaemon

/// The shells' reported folders by surface: kept for the generation that
/// named the surfaces, dropped when the daemon restarts with a new one.
@MainActor @Suite struct TerminalDirectoriesTests {
    @Test func keepsAPathAndDropsAnUnusableReport() {
        var directories = TerminalDirectories()
        let surface = SurfaceID(rawValue: 3)
        #expect(directories.note("kitty-shell-cwd://host/Users/me/code/web-app", surface: surface) == "/Users/me/code/web-app")
        #expect(directories[surface] == "/Users/me/code/web-app")
        #expect(directories.note("~", surface: surface) == nil)
        #expect(directories[surface] == nil)
    }

    @Test func aNewGenerationDropsTheFolders() {
        var directories = TerminalDirectories()
        let surface = SurfaceID(rawValue: 3)
        directories.follow("A")
        _ = directories.note("file:///src/api", surface: surface)
        directories.follow("A")
        directories.follow(nil)
        #expect(directories[surface] == "/src/api")
        directories.follow("B")
        #expect(directories[surface] == nil)
    }
}
