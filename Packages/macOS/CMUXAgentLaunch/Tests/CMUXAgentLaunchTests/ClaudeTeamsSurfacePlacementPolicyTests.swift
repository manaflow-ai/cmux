import Testing
@testable import CMUXAgentLaunch

@Suite("Claude Teams surface placement policy")
struct ClaudeTeamsSurfacePlacementPolicyTests {
    private let policy = ClaudeTeamsSurfacePlacementPolicy()

    @Test("Requires an independent marker before selecting a placement")
    func requiresIndependentMarker() {
        #expect(
            ClaudeTeamsSurfacePlacementPolicy.hasExplicitTeamsMarker([
                ClaudeTeamsSurfacePlacementPolicy.teamsMarkerEnvironmentKey: "1"
            ])
        )
        #expect(
            !ClaudeTeamsSurfacePlacementPolicy.hasExplicitTeamsMarker([
                ClaudeTeamsSurfacePlacementPolicy.cmuxExecutableEnvironmentKey: "/Applications/cmux"
            ])
        )
        #expect(
            policy.placement(
                rawValue: "surface",
                fallback: .surface,
                environment: ["CMUX_CLAUDE_TEAMS_TMUX_SHIM": "/private/tmux"]
            ) == .workspace
        )
        #expect(
            policy.placement(
                rawValue: "surface",
                fallback: .surface,
                environment: [ClaudeTeamsSurfacePlacementPolicy.cmuxExecutableEnvironmentKey: "   "]
            ) == .workspace
        )
        #expect(
            policy.placement(
                rawValue: nil,
                fallback: .surface,
                environment: [
                    ClaudeTeamsSurfacePlacementPolicy.teamsMarkerEnvironmentKey: "1"
                ]
            ) == .surface
        )
    }

    @Test("Explicit placement overrides the injected fallback")
    func explicitPlacementWins() {
        let environment = [
            ClaudeTeamsSurfacePlacementPolicy.teamsMarkerEnvironmentKey: "1"
        ]
        #expect(policy.placement(rawValue: "surface", fallback: .workspace, environment: environment) == .surface)
        #expect(policy.placement(rawValue: "unknown", fallback: .surface, environment: environment) == .surface)
    }

    @Test("Control environment drops unsafe values and preserves safe context")
    func controlEnvironmentIsSafe() {
        let environment = [
            ClaudeTeamsSurfacePlacementPolicy.teamsMarkerEnvironmentKey: "1",
            ClaudeTeamsSurfacePlacementPolicy.cmuxExecutableEnvironmentKey: "/Applications/cmux/bin/cmux",
            "CMUX_CLAUDE_TEAMS_TMUX_SHIM": "/private/tmux",
            "TMUX": "/tmp/cmux.sock,1,0",
            "CLAUDE_CODE_SANDBOXED": "1\nexport BAD=1",
        ]
        let selected = policy.controlEnvironment(from: environment, placementRawValue: "surface")
        #expect(selected[ClaudeTeamsSurfacePlacementPolicy.cmuxExecutableEnvironmentKey] == "/Applications/cmux/bin/cmux")
        #expect(selected["CMUX_CLAUDE_TEAMS_TMUX_SHIM"] == "/private/tmux")
        #expect(selected["TMUX"] == "/tmp/cmux.sock,1,0")
        #expect(selected["CLAUDE_CODE_SANDBOXED"] == nil)
        #expect(selected["CMUX_CLAUDE_TEAMS_SPAWN_PLACEMENT"] == "surface")
    }

    @Test("Startup environment combines transport and surface identity")
    func startupEnvironmentCombinesInputs() {
        let startup = policy.startupEnvironment(
            aliasToken: "%cmux-surface-11111111-1111-4111-8111-111111111111",
            transportEnvironment: [
                "PATH": "/opt/bin:/usr/bin",
                "CLAUDE_CONFIG_DIR": "/Users/test/.claude",
                "ANTHROPIC_API_KEY": "must-not-be-copied",
            ],
            processEnvironment: [
                ClaudeTeamsSurfacePlacementPolicy.teamsMarkerEnvironmentKey: "1",
                "CMUX_BUNDLED_CLI_PATH": "/Applications/cmux/bin/cmux",
            ]
        )
        #expect(startup["PATH"] == "/opt/bin:/usr/bin")
        #expect(startup["CLAUDE_CONFIG_DIR"] == "/Users/test/.claude")
        #expect(startup["ANTHROPIC_API_KEY"] == nil)
        #expect(startup["CMUX_CLAUDE_TEAMS_SPAWN_PLACEMENT"] == "surface")
        #expect(startup["TMUX_PANE"]?.hasPrefix("%cmux-surface-") == true)
        #expect(startup[ClaudeTeamsSurfacePlacementPolicy.cmuxExecutableEnvironmentKey] == "/Applications/cmux/bin/cmux")
    }

    @Test("Surface aliases round trip and reject malformed tokens")
    func surfaceAliasRoundTrip() {
        let id = "11111111-1111-4111-8111-111111111111"
        let token = ClaudeTeamsSurfacePlacementPolicy.surfaceAliasToken(surfaceID: id)
        #expect(ClaudeTeamsSurfacePlacementPolicy.surfaceID(fromAlias: token) == id)
        #expect(ClaudeTeamsSurfacePlacementPolicy.surfaceID(fromAlias: token.uppercased()) != nil)
        #expect(ClaudeTeamsSurfacePlacementPolicy.surfaceID(fromAlias: "%cmux-surface-not-a-uuid") == nil)
        #expect(ClaudeTeamsSurfacePlacementPolicy.surfaceID(fromAlias: "surface:\(id)") == nil)
    }
}
