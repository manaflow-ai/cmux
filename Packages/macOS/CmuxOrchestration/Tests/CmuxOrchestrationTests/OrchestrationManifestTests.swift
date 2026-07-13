import Foundation
import Testing
@testable import CmuxOrchestration

@Suite struct OrchestrationVersionTests {
    @Test func parsesOneTwoAndThreeComponents() {
        #expect(OrchestrationVersion(string: "1") == OrchestrationVersion(major: 1))
        #expect(OrchestrationVersion(string: "0.42") == OrchestrationVersion(major: 0, minor: 42))
        #expect(OrchestrationVersion(string: "1.2.3") == OrchestrationVersion(major: 1, minor: 2, patch: 3))
    }

    @Test func rejectsMalformedVersions() {
        for bad in ["", "v1", "1.2.3.4", "1..2", "-1.0", "1.x", "1.2-beta"] {
            #expect(OrchestrationVersion(string: bad) == nil, "expected '\(bad)' to be rejected")
        }
    }

    @Test func ordersNumerically() throws {
        let a = try #require(OrchestrationVersion(string: "0.9.9"))
        let b = try #require(OrchestrationVersion(string: "0.10"))
        let c = try #require(OrchestrationVersion(string: "1.0.0"))
        #expect(a < b)
        #expect(b < c)
        #expect(!(c < a))
    }
}

@Suite struct OrchestrationManifestParserTests {
    @Test func parsesMinimalManifest() throws {
        let output = try OrchestrationManifestParser.parse(data: Data(minimalManifestJSON().utf8))
        let manifest = output.manifest
        #expect(manifest.name == "demo-fleet")
        #expect(manifest.version == "1.0.0")
        #expect(manifest.substrate == .worktree(branchPrefix: nil))
        #expect(manifest.agents.count == 1)
        #expect(manifest.parameters.map(\.key) == ["repo_root", "concurrency"])
        #expect(manifest.parameters[1].defaultValue == .int(2))
        #expect(output.unknownKeys.isEmpty)
    }

    @Test func reportsUnknownTopLevelKeys() throws {
        let json = minimalManifestJSON(extra: ",\n  \"defualtAgent\": \"claude\"")
        let output = try OrchestrationManifestParser.parse(data: Data(json.utf8))
        #expect(output.unknownKeys == ["defualtAgent"])
    }

    @Test func rejectsNewerSchemaVersions() {
        let json = minimalManifestJSON().replacingOccurrences(
            of: "\"schemaVersion\": 1",
            with: "\"schemaVersion\": 99"
        )
        #expect(throws: OrchestrationManifestError.self) {
            try OrchestrationManifestParser.parse(data: Data(json.utf8))
        }
    }

    @Test func missingRequiredKeyProducesActionableError() {
        let json = "{ \"schemaVersion\": 1, \"name\": \"x\" }"
        do {
            _ = try OrchestrationManifestParser.parse(data: Data(json.utf8))
            Issue.record("expected parse to throw")
        } catch let error as OrchestrationManifestError {
            #expect(error.message.contains("missing required key"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func rejectsNonJSONAndNonObjectDocuments() {
        #expect(throws: OrchestrationManifestError.self) {
            try OrchestrationManifestParser.parse(data: Data("not json".utf8))
        }
        #expect(throws: OrchestrationManifestError.self) {
            try OrchestrationManifestParser.parse(data: Data("[1, 2]".utf8))
        }
    }

    @Test func decodesSubstrateVariants() throws {
        let clonePool = try OrchestrationManifestParser.parse(
            data: Data(minimalManifestJSON(substrate: "{ \"kind\": \"clone-pool\", \"poolSize\": 4 }").utf8)
        ).manifest
        #expect(clonePool.substrate == .clonePool(poolSize: 4))

        let script = try OrchestrationManifestParser.parse(
            data: Data(minimalManifestJSON(substrate: "{ \"kind\": \"script\", \"provision\": \"scripts/up.sh\" }").utf8)
        ).manifest
        #expect(script.substrate == .script(provision: "scripts/up.sh", reset: nil))
        #expect(script.substrate.scriptPaths == ["scripts/up.sh"])

        let scriptDefaults = try OrchestrationManifestParser.parse(
            data: Data(minimalManifestJSON(substrate: "{ \"kind\": \"script\" }").utf8)
        ).manifest
        #expect(scriptDefaults.substrate == .script(provision: "scripts/provision-workspace", reset: nil))
    }

    @Test func rejectsUnknownSubstrateKind() {
        #expect(throws: OrchestrationManifestError.self) {
            try OrchestrationManifestParser.parse(
                data: Data(minimalManifestJSON(substrate: "{ \"kind\": \"teleport\" }").utf8)
            )
        }
    }

    @Test func decodesStepsWithSuccessAndFailurePolicies() throws {
        let extra = """
        ,
          "steps": [
            {
              "id": "plan",
              "agent": "claude",
              "prompt": "prompts/task.md",
              "success": { "kind": "hook-event", "event": "Stop" },
              "onFailure": { "kind": "retry", "attempts": 2 }
            },
            {
              "id": "review",
              "agent": "claude",
              "prompt": "prompts/task.md",
              "success": { "kind": "pr-exists" },
              "onFailure": { "kind": "needs-input" }
            }
          ]
        """
        let manifest = try OrchestrationManifestParser.parse(data: Data(minimalManifestJSON(extra: extra).utf8)).manifest
        let steps = try #require(manifest.steps)
        #expect(steps[0].success == .hookEvent(name: "Stop"))
        #expect(steps[0].onFailure == .retry(attempts: 2))
        #expect(steps[1].success == .prExists)
        #expect(steps[1].onFailure == .needsInput)
    }

    @Test func manifestRoundTripsThroughCodable() throws {
        let original = try OrchestrationManifestParser.parse(data: Data(minimalManifestJSON().utf8)).manifest
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OrchestrationManifest.self, from: encoded)
        #expect(decoded == original)
    }

    @Test func effectiveDefaultAgentPrefersDeclaredDefaultThenFirstStep() throws {
        let twoAgents = """
        ,
          "defaultAgent": "codex"
        """
        var json = minimalManifestJSON(extra: twoAgents)
        json = json.replacingOccurrences(
            of: "\"agents\": [\n    { \"id\": \"claude\", \"registryAgent\": \"claude\", \"command\": \"claude {{prompt}}\" }\n  ]",
            with: "\"agents\": [ { \"id\": \"claude\", \"command\": \"claude {{prompt}}\" }, { \"id\": \"codex\", \"command\": \"codex exec {{prompt}}\" } ]"
        )
        let manifest = try OrchestrationManifestParser.parse(data: Data(json.utf8)).manifest
        #expect(manifest.effectiveDefaultAgent?.id == "codex")
    }

    @Test func validatesTemplateNames() {
        #expect(OrchestrationManifest.isValidName("issue-fleet"))
        #expect(OrchestrationManifest.isValidName("a1"))
        #expect(!OrchestrationManifest.isValidName(""))
        #expect(!OrchestrationManifest.isValidName("-lead"))
        #expect(!OrchestrationManifest.isValidName("trail-"))
        #expect(!OrchestrationManifest.isValidName("Big"))
        #expect(!OrchestrationManifest.isValidName("has space"))
        #expect(!OrchestrationManifest.isValidName("dot.name"))
    }
}

@Suite struct OrchestrationParameterTests {
    @Test func validatesParameterKeys() {
        #expect(OrchestrationParameter.isValidKey("repo_root"))
        #expect(OrchestrationParameter.isValidKey("a2"))
        #expect(!OrchestrationParameter.isValidKey("RepoRoot"))
        #expect(!OrchestrationParameter.isValidKey("2fast"))
        #expect(!OrchestrationParameter.isValidKey("has-hyphen"))
        #expect(!OrchestrationParameter.isValidKey(""))
    }

    @Test func coercesByType() {
        let intParam = OrchestrationParameter(key: "n", prompt: "n", type: .int)
        #expect(intParam.coerce("5") == .success(.int(5)))
        #expect(intParam.coerce("five") == .failure(.init(key: "n", reason: "expected an integer, got 'five'")))

        let boolParam = OrchestrationParameter(key: "b", prompt: "b", type: .bool)
        #expect(boolParam.coerce("YES") == .success(.bool(true)))
        #expect(boolParam.coerce("0") == .success(.bool(false)))
        if case .success = boolParam.coerce("maybe") { Issue.record("expected failure") }

        let choiceParam = OrchestrationParameter(key: "c", prompt: "c", type: .choice, choices: ["a", "b"])
        #expect(choiceParam.coerce("a") == .success(.string("a")))
        if case .success = choiceParam.coerce("z") { Issue.record("expected failure") }

        let stringParam = OrchestrationParameter(key: "s", prompt: "s", type: .string)
        if case .success = stringParam.coerce("   ") { Issue.record("expected failure for blank") }
    }

    @Test func parameterValuePreservesJSONTypes() throws {
        let json = "[true, 3, \"x\"]"
        let values = try JSONDecoder().decode([OrchestrationParameterValue].self, from: Data(json.utf8))
        #expect(values == [.bool(true), .int(3), .string("x")])
        let encoded = String(data: try JSONEncoder().encode(values), encoding: .utf8)
        #expect(encoded == "[true,3,\"x\"]")
    }
}
