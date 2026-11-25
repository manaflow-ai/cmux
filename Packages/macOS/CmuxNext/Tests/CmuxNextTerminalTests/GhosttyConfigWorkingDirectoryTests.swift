@testable import CmuxNextTerminal
import Foundation
import Testing

/// Ghostty's `working-directory` (user, Nov 12: "there's a ghostty setting for default dir that
/// cmux-next needs to respect"): the folder a new terminal starts in when nothing names one and
/// nothing lends one.
struct GhosttyConfigWorkingDirectoryTests {
    private let home = "/Users/someone"
    private let folders: Set<String> = ["/Users/someone", "/Users/someone/fun", "/srv/work", "/Users/someone/my dir"]
    private func exists(_ path: String) -> Bool { folders.contains(path) }

    @Test(arguments: [
        ("working-directory = ~/fun", "/Users/someone/fun"),
        ("working-directory = /srv/work", "/srv/work"),
        ("working-directory = home", "/Users/someone"),
        (#"working-directory = "~/my dir""#, "/Users/someone/my dir"),
    ])
    func eachGhosttyValueNamesItsFolder(line: String, folder: String) {
        let value = GhosttyConfigWorkingDirectory.value(configText: line)
        #expect(value?.start(home: home, isDirectory: exists) == folder)
    }

    @Test func inheritAndUnsetLeaveTheDaemonDefault() {
        #expect(GhosttyConfigWorkingDirectory.value(configText: "working-directory = inherit")?.start(home: home, isDirectory: exists) == nil)
        #expect(GhosttyConfigWorkingDirectory.value(configText: "font-size = 12\n# working-directory = ~/fun") == nil)
    }

    @Test func theLastLineWinsAndAnEmptyValueResets() {
        #expect(GhosttyConfigWorkingDirectory.value(configText: "working-directory = /srv/work\nworking-directory = ~/fun")
            == .path("~/fun"))
        #expect(GhosttyConfigWorkingDirectory.value(configText: "working-directory = /srv/work\nworking-directory =") == nil)
    }

    @Test func aMissingOrRelativeFolderIsNotUsed() {
        #expect(GhosttyConfigWorkingDirectory.value(configText: "working-directory = /gone")?.start(home: home, isDirectory: exists) == nil)
        #expect(GhosttyConfigWorkingDirectory.value(configText: "working-directory = fun")?.start(home: home, isDirectory: exists) == nil)
    }

    /// The loaded files in Ghostty's order (XDG config, then Application Support, then includes): the later file wins.
    @Test func theLaterLoadedFileWins() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "working-directory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let xdg = directory.appending(path: "config"), native = directory.appending(path: "config.ghostty")
        try "working-directory = /srv/work\n".write(to: xdg, atomically: true, encoding: .utf8)
        try "theme = x\nworking-directory = ~/fun\n".write(to: native, atomically: true, encoding: .utf8)
        #expect(GhosttyConfigWorkingDirectory.value(inFiles: [xdg.path, native.path]) == .path("~/fun"))
        #expect(GhosttyConfigWorkingDirectory.value(inFiles: [native.path, xdg.path]) == .path("/srv/work"))
    }

    /// `*-inherit-working-directory = false`: that kind of new terminal starts in `working-directory`, else home.
    @Test func anUninheritedTerminalStartsInTheConfiguredFolder() {
        let configured = GhosttyWorkingDirectoryInheritance(window: false, tab: true, split: false, configuredStart: "/Users/someone/fun")
        #expect(configured.uninheritedStart(.window, home: home) == "/Users/someone/fun")
        #expect(configured.uninheritedStart(.split, home: home) == "/Users/someone/fun")
        #expect(configured.uninheritedStart(.tab, home: home) == nil)
        let unset = GhosttyWorkingDirectoryInheritance(window: false)
        #expect(unset.uninheritedStart(.window, home: home) == home)
    }
}
