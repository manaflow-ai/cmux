import Foundation
import Testing
@testable import CmuxFoundation

@Suite("Remote workspace terminal profiles")
struct WorkspaceRemoteTerminalProfileTests {
    @Test("legacy and explicit shell values normalize to the shell profile")
    func shellDefaults() {
        #expect(WorkspaceRemoteTerminalProfile(
            remoteConfigurationValue: nil,
            tmuxSessionName: nil
        ) == .shell)
        #expect(WorkspaceRemoteTerminalProfile(
            remoteConfigurationValue: " SHELL\n",
            tmuxSessionName: nil
        ) == .shell)
    }

    @Test("tmux profiles normalize and retain a named session")
    func namedTmuxSession() throws {
        let profile = try #require(WorkspaceRemoteTerminalProfile(
            remoteConfigurationValue: " TMUX ",
            tmuxSessionName: " agent main "
        ))

        #expect(profile.kind == .tmux)
        #expect(profile.tmuxSessionName == "agent main")
        #expect(profile.remoteCommandArguments.suffix(4) == [
            "new-session", "-A", "-s", "agent main",
        ])
    }

    @Test("tmux profiles default to the main session")
    func defaultTmuxSession() throws {
        let profile = try #require(WorkspaceRemoteTerminalProfile(
            remoteConfigurationValue: "tmux",
            tmuxSessionName: nil
        ))

        #expect(profile == .defaultTmux)
        #expect(profile.tmuxSessionName == "main")
    }

    @Test("invalid profile and hidden session values are rejected")
    func rejectsInvalidValues() {
        #expect(WorkspaceRemoteTerminalProfile(
            remoteConfigurationValue: "screen",
            tmuxSessionName: nil
        ) == nil)
        #expect(WorkspaceRemoteTerminalProfile(
            remoteConfigurationValue: "shell",
            tmuxSessionName: "main"
        ) == nil)
        #expect(WorkspaceRemoteTerminalProfile(
            remoteConfigurationValue: "tmux",
            tmuxSessionName: "main\nother"
        ) == nil)
    }

    @Test(
        "tmux target separators are rejected before tmux normalizes them",
        arguments: ["feature.v2", "feature:v2"]
    )
    func rejectsTmuxTargetSeparators(_ sessionName: String) {
        #expect(WorkspaceRemoteTerminalProfile(
            kind: .tmux,
            tmuxSessionName: sessionName
        ) == nil)
    }

    @Test("profile persistence round-trips the typed tmux intent")
    func codableRoundTrip() throws {
        let original = try #require(WorkspaceRemoteTerminalProfile(
            kind: .tmux,
            tmuxSessionName: "agent-main"
        ))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WorkspaceRemoteTerminalProfile.self, from: data)

        #expect(decoded == original)
    }
}
