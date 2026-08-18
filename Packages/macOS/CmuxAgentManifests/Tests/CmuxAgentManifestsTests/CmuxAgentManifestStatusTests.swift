import CmuxAgentManifests
import CmuxCore
import Foundation
import Testing

@Suite("Bundled agent status contracts")
struct CmuxAgentManifestStatusTests {
    private struct StatusFixture: Sendable {
        let classification: CmuxAgentClassification
        let screen: String
        let ruleID: String
        let conditionID: String
    }

    private struct AgentFixture: Sendable {
        let id: String
        let process: CmuxAgentProcessSnapshot
        let states: [StatusFixture]
        let helpText: String
    }

    @Test("Every bundled CLI maps its real prompt cues to all five states")
    func everyBundledCLIHasStatusContract() throws {
        let snapshot = try CmuxAgentManifestLoader.bundled().load()
        #expect(snapshot.entries.count == Self.fixtures.count)

        for fixture in Self.fixtures {
            let entry = try #require(snapshot.entry(id: fixture.id))
            #expect(Set(entry.manifest.states.map(\.state)) == Set(CmuxAgentDetectionState.allCases))

            let identity = snapshot.engine.detect(process: fixture.process)
            #expect(identity.agentID == fixture.id)
            #expect(identity.source == .bundled)

            for state in fixture.states {
                let result = snapshot.engine.detect(
                    process: fixture.process,
                    screen: state.screen
                )
                #expect(result.agentID == fixture.id, "\(fixture.id): \(state.screen)")
                #expect(result.classification == state.classification, "\(fixture.id): \(state.screen)")
                #expect(result.stateRuleID == state.ruleID)
                let matchedTrace = result.trace.contains {
                    $0.phase == .state
                        && $0.ruleID == state.ruleID
                        && $0.conditionID == state.conditionID
                        && $0.matched
                }
                #expect(matchedTrace)

                let fast = snapshot.engine.classify(
                    manifestID: fixture.id,
                    screen: state.screen
                )
                #expect(fast.classification == state.classification)
                #expect(fast.stateRuleID == state.ruleID)
            }
        }
    }

    @Test("Help and ordinary output fail closed for every bundled CLI")
    func helpOutputDoesNotInventState() throws {
        let snapshot = try CmuxAgentManifestLoader.bundled().load()
        for fixture in Self.fixtures {
            let result = snapshot.engine.detect(
                process: fixture.process,
                screen: fixture.helpText
            )
            #expect(result.agentID == fixture.id)
            #expect(result.classification == .unknown)
            #expect(result.stateRuleID == nil)
        }
    }

    @Test("Observed CLI transcripts use only a real prompt cue")
    func observedCLITranscripts() throws {
        let snapshot = try CmuxAgentManifestLoader.bundled().load()
        let cases: [(id: String, process: CmuxAgentProcessSnapshot, transcript: String, state: CmuxAgentClassification)] = [
            (
                "pi",
                .init(processName: "pi", arguments: ["pi"]),
                "pi v0.73.1\nescape interrupt · ctrl+c/ctrl+d clear/exit · / commands · ! bash",
                .idle
            ),
            (
                "kimi",
                .init(processName: "Kimi Code"),
                "Welcome to Kimi Code CLI!\nSend /help for help information.\n── input ─────────────────────────────────",
                .idle
            ),
            (
                "antigravity",
                .init(processName: "agy"),
                "Authentication required. Please visit the URL to log in:\nWaiting for authentication (timeout 60s)...",
                .unknown
            ),
            (
                "grok",
                .init(processName: "grok"),
                "",
                .unknown
            ),
            (
                "hermes-agent",
                .init(
                    processName: "python",
                    processPath: "/Users/example/.hermes/hermes-agent/venv/bin/python",
                    arguments: [
                        "/Users/example/.hermes/hermes-agent/venv/bin/python",
                        "/Users/example/.hermes/hermes-agent/run_agent.py",
                    ]
                ),
                "🤖 AI Agent with Tool Calling\n❌ Failed to initialize agent: No LLM provider configured.",
                .unknown
            ),
            (
                "campfire",
                .init(processName: "campfire"),
                "campfire --help\nOptions: --prompt --permission-mode --thinking",
                .unknown
            ),
            (
                "omp",
                .init(processName: "omp"),
                "omp --help\nOptions: --prompt --permission --thinking",
                .unknown
            ),
        ]

        for fixture in cases {
            let result = snapshot.engine.detect(
                process: fixture.process,
                screen: fixture.transcript
            )
            #expect(result.agentID == fixture.id, "\(fixture.id)")
            #expect(result.classification == fixture.state, "\(fixture.id)")
            if fixture.state == .unknown {
                #expect(result.stateRuleID == nil, "\(fixture.id)")
            }
        }
    }

    @Test("Permission, blocked, done, and working cues keep their precedence")
    func overlappingCuesUseDeclaredPrecedence() throws {
        let snapshot = try CmuxAgentManifestLoader.bundled().load()
        let fixtures = Self.fixtures
        for fixture in fixtures {
            let permission = fixture.states[0].screen
            let blocked = fixture.states[1].screen
            let done = fixture.states[2].screen
            let working = fixture.states[3].screen
            let idle = fixture.states[4].screen

            let permissionOverBlocked = snapshot.engine.detect(
                process: fixture.process,
                screen: permission + "\n" + blocked
            )
            #expect(permissionOverBlocked.classification == .permissionPrompt)

            let blockedOverDone = snapshot.engine.detect(
                process: fixture.process,
                screen: done + "\n" + blocked
            )
            #expect(blockedOverDone.classification == .blocked)

            let doneOverWorking = snapshot.engine.detect(
                process: fixture.process,
                screen: done + "\n" + working
            )
            #expect(doneOverWorking.classification == .done)

            let workingOverIdle = snapshot.engine.detect(
                process: fixture.process,
                screen: idle + "\n" + working
            )
            #expect(workingOverIdle.classification == .working)
        }
    }

    @Test("Grok's legacy agent alias is path-scoped and cannot match Cursor Agent")
    func grokLegacyAliasIsNotBroad() throws {
        let snapshot = try CmuxAgentManifestLoader.bundled().load()
        let grok = snapshot.engine.detect(
            process: .init(
                processName: "agent",
                processPath: "/Users/example/.grok/bin/agent",
                arguments: ["/Users/example/.grok/bin/agent"]
            )
        )
        #expect(grok.agentID == "grok")
        #expect(grok.processMatcherID == "legacy-agent-alias")

        let cursor = snapshot.engine.detect(
            process: .init(
                processName: "agent",
                processPath: "/Users/example/.local/bin/agent",
                arguments: ["/Users/example/.local/share/cursor-agent/cursor-agent"]
            )
        )
        #expect(cursor.agentID == nil)
        #expect(cursor.processMatcherID == nil)
    }

    @Test("Compiled fast paths classify every bundled CLI under sustained scans")
    func sustainedFastPathClassification() throws {
        let snapshot = try CmuxAgentManifestLoader.bundled().load()
        var identityMatches = 0
        var stateMatches = 0

        for _ in 0..<1_000 {
            for fixture in Self.fixtures {
                if snapshot.engine.matchingEntry(for: fixture.process)?.entry.manifest.id
                    == fixture.id {
                    identityMatches += 1
                }
                let idle = try #require(fixture.states.last)
                let result = snapshot.engine.classify(
                    manifestID: fixture.id,
                    screen: idle.screen
                )
                if result.classification == idle.classification {
                    stateMatches += 1
                }
            }
        }

        #expect(identityMatches == Self.fixtures.count * 1_000)
        #expect(stateMatches == Self.fixtures.count * 1_000)
    }

    @Test("Maximum bounded screens still reach every bundled idle rule")
    func maximumScreensReachIdleRules() throws {
        let snapshot = try CmuxAgentManifestLoader.bundled().load()
        let filler = String(
            repeating: "x",
            count: CmuxAgentManifestCodec.maximumScreenInputBytes
        )

        for fixture in Self.fixtures {
            let idle = try #require(fixture.states.last)
            let result = snapshot.engine.classify(
                manifestID: fixture.id,
                screen: filler + "\n" + idle.screen
            )
            #expect(result.classification == .idle, "\(fixture.id)")
            #expect(result.stateRuleID == idle.ruleID, "\(fixture.id)")
        }
    }

    private static let fixtures: [AgentFixture] = [
        .init(
            id: "antigravity",
            process: .init(processName: "agy"),
            states: [
                .init(classification: .permissionPrompt, screen: "Do you trust the contents of this project?", ruleID: "permission-prompt", conditionID: "screenContains[0]"),
                .init(classification: .blocked, screen: "Waiting for input", ruleID: "blocked", conditionID: "screenRegex[0]"),
                .init(classification: .done, screen: "✓ Task completed", ruleID: "done", conditionID: "screenRegex[3]"),
                .init(classification: .working, screen: "⠋ Running tool", ruleID: "working", conditionID: "screenRegex[0]"),
                .init(classification: .idle, screen: "> ", ruleID: "idle", conditionID: "screenRegex[0]"),
            ],
            helpText: "Usage of agy:\n  --dangerously-skip-permissions Auto-approve all tool permission requests without prompting\n"
        ),
        .init(
            id: "campfire",
            process: .init(processName: "campfire"),
            states: Self.piFamilyStates,
            helpText: "campfire --help\nOptions: --prompt --permission-mode --thinking\n"
        ),
        .init(
            id: "grok",
            process: .init(processName: "grok"),
            states: [
                .init(classification: .permissionPrompt, screen: "Waiting for approval…", ruleID: "permission-prompt", conditionID: "screenRegex[0]"),
                .init(classification: .blocked, screen: "Waiting for input", ruleID: "blocked", conditionID: "screenRegex[0]"),
                .init(classification: .done, screen: "✓ Task completed", ruleID: "done", conditionID: "screenRegex[3]"),
                .init(classification: .working, screen: "⠙ Running tool", ruleID: "working", conditionID: "screenRegex[0]"),
                .init(classification: .idle, screen: "> ", ruleID: "idle", conditionID: "screenRegex[0]"),
            ],
            helpText: "Grok Build TUI\n      --always-approve Auto-approve all tool executions\n  -m, --model <MODEL> Working directory\n"
        ),
        .init(
            id: "hermes-agent",
            process: .init(
                processName: "python3.11",
                processPath: "/Users/example/.local/share/uv/python/bin/python3.11",
                arguments: [
                    "/Users/example/.hermes/hermes-agent/venv/bin/python",
                    "/Users/example/.hermes/hermes-agent/run_agent.py",
                ]
            ),
            states: [
                .init(classification: .permissionPrompt, screen: "Allow this tool?", ruleID: "permission-prompt", conditionID: "screenRegex[0]"),
                .init(classification: .blocked, screen: "Waiting for input", ruleID: "blocked", conditionID: "screenRegex[0]"),
                .init(classification: .done, screen: "✓ Task completed", ruleID: "done", conditionID: "screenRegex[3]"),
                .init(classification: .working, screen: "starting agent…", ruleID: "working", conditionID: "screenContains[0]"),
                .init(classification: .idle, screen: "❯ ", ruleID: "idle", conditionID: "screenRegex[0]"),
            ],
            helpText: "Hermes Agent\n  --yolo Bypass all dangerous command approval prompts\n  --accept-hooks Auto-approve unseen shell hooks\n"
        ),
        .init(
            id: "kimi",
            process: .init(
                processName: "Kimi Code",
                processPath: "/Users/example/.local/share/uv/python/bin/python3.13",
                arguments: ["Kimi Code", ""]
            ),
            states: [
                .init(classification: .permissionPrompt, screen: "Approve this action?", ruleID: "permission-prompt", conditionID: "screenRegex[0]"),
                .init(classification: .blocked, screen: "Waiting for input", ruleID: "blocked", conditionID: "screenRegex[0]"),
                .init(classification: .done, screen: "✓ Task completed", ruleID: "done", conditionID: "screenRegex[3]"),
                .init(classification: .working, screen: "⠹ Running tool", ruleID: "working", conditionID: "screenRegex[0]"),
                .init(classification: .idle, screen: "── input ─────────────────", ruleID: "idle", conditionID: "screenRegex[0]"),
            ],
            helpText: "Kimi Code CLI\n│ --thinking --no-thinking Enable thinking │\n│ approve all tool calls automatically │\n"
        ),
        .init(
            id: "omp",
            process: .init(processName: "omp"),
            states: Self.piFamilyStates,
            helpText: "omp --help\nOptions: --thinking --prompt --permission\n"
        ),
        .init(
            id: "pi",
            process: .init(processName: "pi", arguments: ["pi"]),
            states: Self.piFamilyStates,
            helpText: "pi - AI coding assistant\n  --thinking <level> Set thinking level\n  --prompt-template <path>\n"
        ),
    ]

    private static let piFamilyStates: [StatusFixture] = [
        .init(classification: .permissionPrompt, screen: "Allow this tool?", ruleID: "permission-prompt", conditionID: "screenRegex[0]"),
        .init(classification: .blocked, screen: "Waiting for input", ruleID: "blocked", conditionID: "screenRegex[0]"),
        .init(classification: .done, screen: "✓ Task completed", ruleID: "done", conditionID: "screenRegex[3]"),
        .init(classification: .working, screen: "⠋ Running tool", ruleID: "working", conditionID: "screenRegex[0]"),
        .init(classification: .idle, screen: "escape interrupt · ctrl+c/ctrl+d clear/exit · / commands", ruleID: "idle", conditionID: "screenContains[0]"),
    ]
}
