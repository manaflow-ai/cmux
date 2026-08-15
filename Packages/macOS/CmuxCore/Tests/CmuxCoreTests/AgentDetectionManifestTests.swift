import Foundation
import Testing
@testable import CmuxCore

@Suite("Agent detection manifests")
struct AgentDetectionManifestTests {
    @Test("Process path predicates and alternate matchers remain deterministic")
    func processMatcherVariants() throws {
        let manifest = CmuxAgentDetectionManifest(
            id: "path-agent",
            process: .init(matchers: [
                .init(
                    id: "path",
                    processPathContains: ["/opt/tools"],
                    processPathRegex: [.init(pattern: "agent[-.]cli$")]
                ),
                .init(id: "alternate", argvContainsAny: ["--agent-mode"]),
            ]),
            states: [.init(id: "idle", state: .idle, screenContains: ["ready"])]
        )
        try CmuxAgentManifestCodec.validate(manifest)
        let engine = CmuxAgentDetectionEngine(entries: [.init(manifest: manifest, source: .user)])
        let pathResult = engine.detect(
            process: .init(processName: "agent", processPath: "/opt/tools/agent-cli", arguments: ["agent-cli"])
        )
        #expect(pathResult.processMatcherID == "path")
        let alternateResult = engine.detect(
            process: .init(processName: "wrapper", arguments: ["wrapper", "--agent-mode"])
        )
        #expect(alternateResult.processMatcherID == "alternate")
        let negative = engine.detect(
            process: .init(processName: "agent", processPath: "/usr/bin/agent-cli", arguments: ["agent-cli"])
        )
        #expect(negative.agentID == nil)
    }

    @Test("User manifests win deterministic overlaps with bundled entries")
    func userManifestPrecedence() throws {
        let bundled = CmuxAgentDetectionManifest(
            id: "bundled",
            process: .init(matchers: [.init(id: "bundled-match", processNames: ["shared-cli"])]),
            states: [.init(id: "idle", state: .idle, screenContains: ["ready"])]
        )
        let user = CmuxAgentDetectionManifest(
            id: "user",
            process: .init(matchers: [.init(id: "user-match", processNames: ["shared-cli"])]),
            states: [.init(id: "done", state: .done, screenContains: ["finished"])]
        )
        let result = CmuxAgentDetectionEngine(entries: [
            .init(manifest: bundled, source: .bundled),
            .init(manifest: user, source: .user),
        ]).detect(process: .init(processName: "shared-cli"), screen: "finished")
        #expect(result.agentID == "user")
        #expect(result.source == .user)
    }

    @Test("Ordered screen, regex, and OSC rules return a detailed match")
    func stateRulesAndTrace() throws {
        let manifest = CmuxAgentDetectionManifest(
            id: "fixture",
            process: .init(matchers: [.init(id: "shell", processNames: ["fixture"]) ]),
            states: [
                .init(id: "permission", state: .permissionPrompt, screenRegex: [.init(pattern: "approve")]),
                .init(id: "osc-idle", state: .idle, osc: [.init(sequence: "\u{1B}]9;cmux;idle\u{07}", mode: .exact)]),
                .init(id: "working", state: .working, screenContains: ["working"]),
            ]
        )
        try CmuxAgentManifestCodec.validate(manifest)
        let engine = CmuxAgentDetectionEngine(entries: [.init(manifest: manifest, source: .user, sourcePath: "/tmp/fixture.json")])

        let permission = engine.detect(
            process: .init(processName: "fixture"),
            screen: "Approve this tool?"
        )
        #expect(permission.classification == .permissionPrompt)
        #expect(permission.stateRuleID == "permission")
        #expect(permission.processMatcherID == "shell")
        #expect(permission.source == .user)
        #expect(permission.trace.contains { $0.ruleID == "permission" && $0.matched })
        #expect(permission.trace.contains {
            $0.manifestID == "fixture"
                && $0.ruleID == "permission"
                && $0.conditionID == "screenRegex[0]"
        })

        let idle = engine.detect(
            process: .init(processName: "fixture"),
            osc: "\u{1B}]9;cmux;idle\u{07}"
        )
        #expect(idle.classification == .idle)
        #expect(idle.stateRuleID == "osc-idle")
    }

    @Test("A bounded trace retains selected process and state rules after many failures")
    func boundedTraceRetainsSelections() {
        let entries = (0..<6).map { manifestIndex in
            CmuxAgentManifestEntry(
                manifest: CmuxAgentDetectionManifest(
                    id: "fixture-\(manifestIndex)",
                    process: .init(matchers: (0..<64).map { matcherIndex in
                        .init(
                            id: "match-\(matcherIndex)",
                            processNames: [
                                manifestIndex == 5 && matcherIndex == 63
                                    ? "selected-agent"
                                    : "miss-\(manifestIndex)-\(matcherIndex)",
                            ]
                        )
                    }),
                    states: manifestIndex == 5 ? (0..<128).map { ruleIndex in
                        .init(
                            id: "state-\(ruleIndex)",
                            state: .done,
                            screenContains: [ruleIndex == 127 ? "selected-state" : "miss-state-\(ruleIndex)"]
                        )
                    } : []
                ),
                source: .bundled
            )
        }

        let result = CmuxAgentDetectionEngine(entries: entries).detect(
            process: .init(processName: "selected-agent"),
            screen: "selected-state"
        )

        #expect(result.agentID == "fixture-5")
        #expect(result.classification == .done)
        #expect(result.trace.count == 256)
        #expect(result.trace.contains {
            $0.manifestID == "fixture-5" && $0.ruleID == "match-63" && $0.matched
        })
        #expect(result.trace.contains {
            $0.manifestID == "fixture-5" && $0.ruleID == "state-127" && $0.matched
        })
    }

    @Test("Malformed manifests fail closed with actionable paths")
    func validationRejectsMalformedInput() throws {
        let invalidRegex = Data(#"{"id":"bad","process":{"matchers":[{"processNames":["bad"]}]},"states":[{"id":"x","state":"idle","screenRegex":["["]}]}"#.utf8)
        do {
            _ = try CmuxAgentManifestCodec.decode(data: invalidRegex)
            Issue.record("invalid regex was accepted")
        } catch let error as CmuxAgentManifestValidationError {
            #expect(error.path.contains("screenRegex"))
        }

        let unknownKey = Data(#"{"id":"bad","process":{"matchers":[{"processNames":["bad"]}]},"wat":"nope"}"#.utf8)
        do {
            _ = try CmuxAgentManifestCodec.decode(data: unknownKey)
            Issue.record("unknown key was accepted")
        } catch let error as CmuxAgentManifestValidationError {
            #expect(error.path == "wat")
        }

        let malformedOSC = CmuxAgentDetectionManifest(
            id: "bad-osc",
            process: .init(matchers: [.init(processNames: ["bad"]) ]),
            states: [.init(id: "x", state: .idle, osc: [.init(sequence: "not-osc")])]
        )
        do {
            try CmuxAgentManifestCodec.validate(malformedOSC)
            Issue.record("malformed OSC was accepted")
        } catch let error as CmuxAgentManifestValidationError {
            #expect(error.reason.contains("ESC"))
        }

        let nullNestedValue = Data(#"{"id":"bad","process":{"matchers":[{"processNames":[null]}]}}"#.utf8)
        do {
            _ = try CmuxAgentManifestCodec.decode(data: nullNestedValue)
            Issue.record("null nested value was accepted")
        } catch let error as CmuxAgentManifestValidationError {
            #expect(error.path == "process.matchers[0].processNames[0]")
            #expect(error.reason.contains("null"))
        }

        let duplicateRules = CmuxAgentDetectionManifest(
            id: "duplicate",
            process: .init(matchers: [.init(id: "same", processNames: ["duplicate"]), .init(id: "same", processNames: ["other"])]),
            states: [.init(id: "same", state: .idle, screenContains: ["ready"]), .init(id: "same", state: .done, screenContains: ["done"])]
        )
        do {
            try CmuxAgentManifestCodec.validate(duplicateRules)
            Issue.record("duplicate rule ids were accepted")
        } catch let error as CmuxAgentManifestValidationError {
            #expect(error.path.contains("process.matchers[1].id"))
        }

        let c1OSC = CmuxAgentDetectionManifest(
            id: "c1-osc",
            process: .init(matchers: [.init(processNames: ["c1-osc"])]),
            states: [.init(id: "idle", state: .idle, osc: [.init(sequence: "\u{9D}9;c1;idle\u{07}", mode: .exact)])]
        )
        try CmuxAgentManifestCodec.validate(c1OSC)
        let c1Result = CmuxAgentDetectionEngine(entries: [.init(manifest: c1OSC, source: .user)]).detect(
            process: .init(processName: "c1-osc"),
            osc: "\u{1B}]9;c1;idle\u{07}"
        )
        #expect(c1Result.classification == .idle)

        let aliasOSC = Data(#"{"id":"alias","process":{"matchers":[{"processNames":["alias"]}]},"states":[{"id":"idle","state":"idle","oscSequences":["\u001b]9;alias;idle\u0007"]}]}"#.utf8)
        let aliasManifest = try CmuxAgentManifestCodec.decode(data: aliasOSC)
        #expect(aliasManifest.states.first?.osc.count == 1)

        let nestedUnknown = Data(#"{"id":"bad","process":{"matchers":[{"processNames":["bad"],"argv":{"contains":"bad"}}]}}"#.utf8)
        do {
            _ = try CmuxAgentManifestCodec.decode(data: nestedUnknown)
            Issue.record("unknown nested key was accepted")
        } catch let error as CmuxAgentManifestValidationError {
            #expect(error.path.contains("argv"))
        }
    }

    @Test("Regexes with unbounded backtracking fail validation")
    func validationRejectsUnsafeRegexes() {
        let unsafePatterns = [
            "(a+)+$",
            "(?:a|aa)+$",
            #"^(a+)\1$"#,
            #"a(?=b)"#,
        ]

        for pattern in unsafePatterns {
            let manifest = CmuxAgentDetectionManifest(
                id: "unsafe-regex",
                process: .init(matchers: [.init(processNames: ["unsafe-regex"])]),
                states: [
                    .init(
                        id: "unsafe",
                        state: .working,
                        screenRegex: [.init(pattern: pattern)]
                    ),
                ]
            )

            do {
                try CmuxAgentManifestCodec.validate(manifest)
                Issue.record("Unsafe regex was accepted: \(pattern)")
            } catch let error as CmuxAgentManifestValidationError {
                #expect(error.path == "states[0].screenRegex[0].pattern")
                #expect(error.reason.localizedCaseInsensitiveContains("safe"))
            } catch {
                Issue.record("Unexpected error for \(pattern): \(error)")
            }
        }
    }

    @Test("Possessive repetition keeps sequential unbounded matches safe")
    func validationAcceptsPossessiveRegexes() throws {
        let safePatterns = [
            #"^\s++for\s++input$"#,
            #"^(?:for\s++)?input$"#,
            #"^question[^\n]*\?$"#,
            #"^.{0,1024}$"#,
        ]

        for pattern in safePatterns {
            let manifest = CmuxAgentDetectionManifest(
                id: "safe-regex",
                process: .init(matchers: [.init(processNames: ["safe-regex"])]),
                states: [
                    .init(
                        id: "safe",
                        state: .working,
                        screenRegex: [.init(pattern: pattern)]
                    ),
                ]
            )

            do {
                try CmuxAgentManifestCodec.validate(manifest)
            } catch {
                Issue.record("Safe regex was rejected: \(pattern): \(error)")
            }
        }
    }

    @Test("Oversized screen captures retain the newest terminal state")
    func oversizedScreenUsesNewestBoundedInput() {
        let manifest = CmuxAgentDetectionManifest(
            id: "bounded-screen",
            process: .init(matchers: [.init(processNames: ["bounded-screen"])]),
            states: [
                .init(id: "old-done", state: .done, screenContains: ["Task completed"]),
                .init(id: "current-idle", state: .idle, screenContains: ["Ready"]),
            ]
        )
        let engine = CmuxAgentDetectionEngine(entries: [
            .init(manifest: manifest, source: .user),
        ])
        let oversizedScreen = "Task completed\n"
            + String(repeating: "x", count: CmuxAgentManifestCodec.maximumScreenInputBytes + 32)
            + "\nReady"

        let result = engine.detect(
            process: .init(processName: "bounded-screen"),
            screen: oversizedScreen
        )

        #expect(result.classification == .idle)
        #expect(result.stateRuleID == "current-idle")
    }

    @Test("State evaluation fails closed after its deterministic work budget")
    func stateEvaluationWorkIsBounded() {
        let manifest = CmuxAgentDetectionManifest(
            id: "bounded-work",
            process: .init(matchers: [.init(processNames: ["bounded-work"])]),
            states: (0..<128).map { index in
                .init(
                    id: "miss-\(index)",
                    state: .working,
                    screenContains: ["missing-\(index)"]
                )
            }
        )
        let engine = CmuxAgentDetectionEngine(entries: [
            .init(manifest: manifest, source: .user),
        ])
        let screen = String(
            repeating: "x",
            count: CmuxAgentManifestCodec.maximumScreenInputBytes
        )

        let result = engine.detect(
            process: .init(processName: "bounded-work"),
            screen: screen
        )

        #expect(result.classification == .unknown)
        #expect(result.trace.contains { $0.detail == "state.budget-exceeded" })
        #expect(result.trace.count < manifest.states.count + 1)
    }
}
