import Foundation
import Testing
@testable import CMUXAgentLaunch

/// The minimal resume binding a relayed Claude hook may carry: session id, remote cwd, and
/// redacted ancestor words. The Mac builds the command; nothing from the relay host is run.
@Suite struct RelayAgentResumeContextTests {
    private let sessionID = "0d15e2d1-ea11-4bcc-873e-e6167dc807aa"

    /// A replay environment carrying the given relay resume fields.
    private func environment(cwd: String? = "/home/leo/repo", ancestors: String? = nil) -> [String: String] {
        var environment: [String: String] = [:]
        environment[RelayAgentResumeContext.remoteWorkingDirectoryEnvironmentKey] = cwd
        environment[RelayAgentResumeContext.ancestorExecutablesEnvironmentKey] = ancestors
        return environment
    }

    private static let teamclaude = AgentExternalLauncher(
        id: "teamclaude",
        kinds: ["claude"],
        argvExecutables: ["teamclaude"],
        resumeArgvPrefix: ["teamclaude", "run", "--auto-fallback", "--"]
    )

    /// Only Claude with a safe session id and an absolute, clean remote cwd yields a context.
    @Test func requiresClaudeASafeSessionAndAnAbsoluteRemoteDirectory() {
        #expect(RelayAgentResumeContext(kind: "claude", sessionID: sessionID, environment: environment()) != nil)
        #expect(RelayAgentResumeContext(kind: "codex", sessionID: sessionID, environment: environment()) == nil)
        #expect(RelayAgentResumeContext(kind: "claude", sessionID: "x; rm -rf /", environment: environment()) == nil)
        #expect(RelayAgentResumeContext(kind: "claude", sessionID: sessionID, environment: environment(cwd: nil)) == nil)
        #expect(RelayAgentResumeContext(kind: "claude", sessionID: sessionID, environment: environment(cwd: "repo")) == nil)
        #expect(RelayAgentResumeContext(kind: "claude", sessionID: sessionID, environment: environment(cwd: "/a\nb")) == nil)
        let long = "/" + String(repeating: "x", count: RelayAgentResumeContext.maximumWorkingDirectoryBytes)
        #expect(RelayAgentResumeContext(kind: "claude", sessionID: sessionID, environment: environment(cwd: long)) == nil)
    }

    /// Redacted words as the remote host ships them still match a declared launcher.
    @Test func detectsADeclaredLauncherFromShippedRedactedWords() throws {
        let registry = AgentExternalLauncherRegistry(launchers: [Self.teamclaude])
        let shipped = #"[["-zsh"],["env","ANTHROPIC_API_KEY=","-u","?","teamclaude"]]"#
        let context = try #require(RelayAgentResumeContext(
            kind: "claude",
            sessionID: sessionID,
            environment: environment(ancestors: shipped)
        ))
        #expect(context.detectedLauncherID(in: registry) == "teamclaude")

        let node = #"[["node","/usr/lib/node_modules/teamclaude/bin/teamclaude"]]"#
        let viaNode = try #require(RelayAgentResumeContext(
            kind: "claude",
            sessionID: sessionID,
            environment: environment(ancestors: node)
        ))
        #expect(viaNode.detectedLauncherID(in: registry) == "teamclaude")

        let unrelated = try #require(RelayAgentResumeContext(
            kind: "claude",
            sessionID: sessionID,
            environment: environment(ancestors: #"[["-bash"]]"#)
        ))
        #expect(unrelated.detectedLauncherID(in: registry) == nil)
    }

    /// Ancestor words outside the relay bounds are dropped as a whole.
    @Test func outOfBoundsAncestorWordsAreDropped() {
        func decoded(_ value: Any) -> [[String]]? {
            let data = try! JSONSerialization.data(withJSONObject: value)
            return RelayAgentResumeContext.decodedAncestorExecutables(json: String(data: data, encoding: .utf8)!)
        }
        #expect(decoded([["teamclaude"]]) == [["teamclaude"]])
        #expect(decoded(Array(repeating: ["a"], count: 9)) == nil)
        #expect(decoded([Array(repeating: "a", count: 7)]) == nil)
        #expect(decoded([[String(repeating: "a", count: 129)]]) == nil)
        #expect(decoded(Array(repeating: [String(repeating: "a", count: 128), String(repeating: "b", count: 128), String(repeating: "c", count: 128)], count: 8)) == nil)
        #expect(decoded([["tab\there"]]) == nil)
        #expect(decoded([[]]) == nil)
        #expect(decoded([["ok", 7]]) == nil)
        #expect(decoded(["flat"]) == nil)
        #expect(RelayAgentResumeContext.decodedAncestorExecutables(json: "not json") == nil)
    }

    /// The stored launch record carries no argv, executable, or environment from the relay.
    @Test func launchRecordCarriesNoArgvExecutableOrEnvironment() throws {
        let context = try #require(RelayAgentResumeContext(
            kind: "claude",
            sessionID: sessionID,
            environment: environment()
        ))
        let record = context.launchCommand(externalLauncherID: "teamclaude", capturedAt: 1)
        #expect(record.arguments.isEmpty)
        #expect(record.executablePath == nil)
        #expect(record.environment == nil)
        #expect(record.workingDirectory == "/home/leo/repo")
        #expect(record.externalLauncher == "teamclaude")
        #expect(RelayAgentResumeContext.isRelayOrigin(source: record.source))
        #expect(!RelayAgentResumeContext.isRelayOrigin(source: "process"))
        #expect(!RelayAgentResumeContext.isRelayOrigin(source: nil))
    }

    /// The Mac builds `claude --resume <id>`, optionally wrapped in its own launcher prefix.
    @Test func macBuildsThePlainClaudeResumeArgv() throws {
        let context = try #require(RelayAgentResumeContext(
            kind: "claude",
            sessionID: sessionID,
            environment: environment()
        ))
        let record = context.launchCommand(externalLauncherID: nil, capturedAt: 1)
        guard case .passthrough = AgentResumeArgv().launcherResolution(
            launcher: record.launcher,
            sessionId: sessionID,
            executablePath: record.executablePath,
            arguments: record.arguments,
            environment: record.environment
        ) else {
            Issue.record("a relay launch record must not resolve through an owned launcher")
            return
        }
        let argv = AgentResumeArgv().builtInKind(
            kind: "claude",
            sessionId: sessionID,
            executablePath: record.executablePath,
            arguments: record.arguments
        )
        #expect(argv == ["claude", "--resume", sessionID])
        #expect(Self.teamclaude.applyingResumePrefix(to: argv ?? []) == [
            "teamclaude", "run", "--auto-fallback", "--", "--resume", sessionID,
        ])
    }
}
