import Foundation
import Testing
@testable import CmuxNextDaemon

/// LAUNCH-NO-TCC-PROMPTS: a kept tab (End Sessions, Keep Layout) whose shell was in a
/// privacy-protected folder restarts when its workspace is shown, never when the app connects:
/// a new shell in ~/Downloads reads it at once, and macOS asks for Downloads in cmux's name at
/// launch. Kept tabs in other folders restart on connect, as before.
@Suite struct KeptTabProtectedFolderTests {
    private let home = "/Users/someone"

    private func relaunch(_ json: String) throws -> TabRelaunch {
        try JSONDecoder().decode(TabRelaunch.self, from: Data(json.utf8))
    }

    @Test(arguments: [
        "/Users/someone/Downloads",
        "/Users/someone/Downloads/project",
        "/Users/someone/desktop/notes",
        "/Users/someone/Documents/",
        "/Users/someone/Library/Mobile Documents/com~apple~CloudDocs/x",
        "/Volumes/External/repo",
        "~/Downloads/project",
    ])
    func aKeptTabInAProtectedFolderWaitsForItsWorkspace(cwd: String) throws {
        let kept = try relaunch(#"{"cwd": \#(String(reflecting: cwd))}"#)
        #expect(kept.startsOnShow(home: home), "\(cwd)")
    }

    @Test(arguments: [
        "/Users/someone/code/cmux",
        "/Users/someone/Downloadsish",
        "/tmp/work",
        "/Users/other/Downloads-copy",
        "/Users/someone",
        "/",
    ])
    func aKeptTabElsewhereRestartsOnConnect(cwd: String) throws {
        let kept = try relaunch(#"{"cwd": \#(String(reflecting: cwd))}"#)
        #expect(!kept.startsOnShow(home: home), "\(cwd)")
    }

    @Test func aParkedTabStillWaitsAndATabWithNoFolderRestartsOnConnect() throws {
        #expect(try relaunch(#"{"cwd": "/tmp/work", "on_show": true}"#).startsOnShow(home: home))
        // No recorded folder: the shell starts in the home folder, which a shell does not list.
        #expect(try !relaunch(#"{"cwd": null}"#).startsOnShow(home: home))
    }
}
