import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The app finds the gh the user's terminal runs: the login shell's PATH comes first, so a wrapper
/// (a quota or logging shim) ahead of Homebrew's gh wins even for an app launched from Finder, whose
/// own PATH lacks it. Before, the lookup read only the App's PATH plus /opt/homebrew/bin and
/// /usr/local/bin, so every PR read in the app skipped the wrapper.
@Suite nonisolated struct AgentPaneGitHubCLILookupTests {
    /// A temporary tree with a wrapper folder and a stand-in Homebrew folder, each holding a `gh`.
    private struct Folders {
        let root: URL
        let wrapper: String
        let homebrew: String

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "gh-lookup-\(UUID().uuidString)")
            wrapper = root.appending(path: "wrapper/bin").path
            homebrew = root.appending(path: "homebrew/bin").path
            for folder in [wrapper, homebrew] {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                let gh = folder + "/gh"
                try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: gh))
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh)
            }
        }
    }

    @Test func loginPathWrapperWinsOverHomebrew() throws {
        let folders = try Folders()
        defer { try? FileManager.default.removeItem(at: folders.root) }
        // The Finder app's PATH has only Homebrew; the login shell puts the wrapper ahead of it.
        let app = ["PATH": folders.homebrew + ":/usr/bin:/bin", "HOME": folders.root.path]
        let login = folders.wrapper + ":" + folders.homebrew + ":/usr/bin:/bin"

        #expect(AgentChatPullRequestReader.findGitHubCLI(app, loginPath: login) == folders.wrapper + "/gh")
        #expect(AgentPaneGitPullRequest.gitHubCLI(app, loginPath: login) == folders.wrapper + "/gh")
        // Without a captured login PATH, the App's PATH still finds gh (the fallback).
        #expect(AgentChatPullRequestReader.findGitHubCLI(app, loginPath: nil) == folders.homebrew + "/gh")
    }

    @Test func ghEnvironmentPutsLoginPathFirst() throws {
        let folders = try Folders()
        defer { try? FileManager.default.removeItem(at: folders.root) }
        let app = ["PATH": folders.homebrew + ":/usr/bin:/bin", "HOME": folders.root.path]
        let login = folders.wrapper + ":" + folders.homebrew

        // The wrapper runs with the same PATH order, so it finds the gh it wraps; no folder twice.
        let path = try #require(AgentChatPullRequestReader.environment(app, loginPath: login)["PATH"])
        let entries = path.split(separator: ":").map(String.init)
        #expect(entries.first == folders.wrapper)
        #expect(entries.contains(folders.root.path + "/.local/bin"))
        #expect(Set(entries).count == entries.count)
        #expect(AgentPaneGitProcess.toolFolders(app, loginPath: login).first == folders.wrapper)
    }
}
