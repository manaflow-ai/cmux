import Foundation
import Testing
@testable import CmuxOrchestration

@Suite struct OrchestrationValidatorTests {
    private func validate(
        configure: (InMemoryFileSystem) -> Void
    ) -> OrchestrationValidationReport {
        let fileSystem = InMemoryFileSystem()
        configure(fileSystem)
        return OrchestrationValidator(fileSystem: fileSystem).validate(templateDirectory: "/t")
    }

    private func codes(_ report: OrchestrationValidationReport) -> Set<String> {
        Set(report.findings.map(\.code))
    }

    @Test func acceptsAValidTemplate() {
        let report = validate { addMinimalTemplate(to: $0, at: "/t") }
        #expect(report.isValid, "unexpected findings: \(report.findings)")
        #expect(report.manifest?.name == "demo-fleet")
    }

    @Test func missingDirectoryAndManifest() {
        let missingDirectory = validate { _ in }
        #expect(codes(missingDirectory) == ["missing-template"])

        let missingManifest = validate { $0.addDirectory("/t") }
        #expect(codes(missingManifest) == ["missing-manifest"])
    }

    @Test func invalidJSONIsOneClearError() {
        let report = validate {
            $0.addDirectory("/t")
            $0.addFile("/t/orchestration.json", "{ nope")
        }
        #expect(codes(report) == ["invalid-manifest"])
        #expect(!report.isValid)
    }

    @Test func flagsUnknownTopLevelKeysAsWarnings() {
        let report = validate {
            addMinimalTemplate(to: $0, at: "/t", extra: ",\n  \"defualtAgent\": \"claude\"")
        }
        #expect(report.isValid)
        #expect(report.warnings.map(\.code) == ["unknown-key"])
    }

    @Test func flagsBadNameVersionAndMinCmuxVersion() {
        let report = validate { fileSystem in
            fileSystem.addDirectory("/t")
            let json = minimalManifestJSON(name: "demo-fleet")
                .replacingOccurrences(of: "\"name\": \"demo-fleet\"", with: "\"name\": \"Bad Name\"")
                .replacingOccurrences(of: "\"version\": \"1.0.0\"", with: "\"version\": \"one\"")
                .replacingOccurrences(of: "\"description\": \"Demo fleet\"", with: "\"description\": \"d\", \"minCmuxVersion\": \"vNext\"")
            fileSystem.addFile("/t/orchestration.json", json)
            fileSystem.addFile("/t/prompts/task.md", "{{task}}")
        }
        #expect(codes(report).isSuperset(of: ["invalid-name", "invalid-version", "invalid-min-cmux-version"]))
    }

    @Test func flagsParameterProblems() {
        let extraParams = """
        {
          "schemaVersion": 1,
          "name": "p",
          "version": "1.0.0",
          "description": "d",
          "parameters": [
            { "key": "dup", "prompt": "a" },
            { "key": "dup", "prompt": "b" },
            { "key": "BadKey", "prompt": "c" },
            { "key": "task", "prompt": "d" },
            { "key": "pick", "prompt": "e", "type": "choice" },
            { "key": "n", "prompt": "f", "type": "int", "default": "x" }
          ],
          "substrate": { "kind": "worktree" },
          "agents": [ { "id": "a", "command": "run {{prompt}}" } ],
          "prompt": "prompts/task.md"
        }
        """
        let report = validate { fileSystem in
            fileSystem.addDirectory("/t")
            fileSystem.addFile("/t/orchestration.json", extraParams)
            fileSystem.addFile("/t/prompts/task.md", "{{task}}")
        }
        #expect(codes(report).isSuperset(of: [
            "duplicate-parameter", "invalid-parameter-key", "reserved-parameter", "empty-choices", "invalid-default",
        ]))
    }

    @Test func flagsAgentAndStepProblems() {
        let json = """
        {
          "schemaVersion": 1,
          "name": "s",
          "version": "1.0.0",
          "description": "d",
          "substrate": { "kind": "worktree" },
          "agents": [
            { "id": "a", "command": "run {{prompt}}" },
            { "id": "a", "command": "echo no prompt" }
          ],
          "defaultAgent": "ghost",
          "steps": [
            { "id": "one", "agent": "missing", "prompt": "prompts/task.md" },
            { "id": "one", "agent": "a", "prompt": "prompts/absent.md" }
          ]
        }
        """
        let report = validate { fileSystem in
            fileSystem.addDirectory("/t")
            fileSystem.addFile("/t/orchestration.json", json)
            fileSystem.addFile("/t/prompts/task.md", "{{task}}")
        }
        #expect(codes(report).isSuperset(of: [
            "duplicate-agent", "command-without-prompt", "unknown-default-agent",
            "duplicate-step", "unknown-agent", "missing-file",
        ]))
    }

    @Test func missingPromptAndEmptyStepsAreErrors() {
        let noPrompt = validate { fileSystem in
            fileSystem.addDirectory("/t")
            let json = minimalManifestJSON().replacingOccurrences(of: ",\n      \"prompt\": \"prompts/task.md\"", with: "")
                .replacingOccurrences(of: "\"prompt\": \"prompts/task.md\"", with: "\"workflow\": \"WORKFLOW.md\"")
            fileSystem.addFile("/t/orchestration.json", json)
            fileSystem.addFile("/t/WORKFLOW.md", "w")
        }
        #expect(codes(noPrompt).contains("no-prompt"))
    }

    @Test func rejectsAbsoluteAndTraversalPaths() {
        let report = validate { fileSystem in
            fileSystem.addDirectory("/t")
            let json = minimalManifestJSON()
                .replacingOccurrences(of: "\"prompt\": \"prompts/task.md\"", with: "\"prompt\": \"../escape.md\", \"layout\": \"/etc/passwd\"")
            fileSystem.addFile("/t/orchestration.json", json)
        }
        let invalidPathFindings = report.findings.filter { $0.code == "invalid-path" }
        #expect(invalidPathFindings.count == 2)
    }

    @Test func scriptSubstrateChecksExistenceAndExecutableBit() {
        let missing = validate { fileSystem in
            addMinimalTemplate(to: fileSystem, at: "/t", substrate: "{ \"kind\": \"script\" }")
        }
        #expect(codes(missing).contains("missing-script"))

        let notExecutable = validate { fileSystem in
            addMinimalTemplate(to: fileSystem, at: "/t", substrate: "{ \"kind\": \"script\" }")
            fileSystem.addFile("/t/scripts/provision-workspace", "#!/bin/sh\n")
        }
        #expect(notExecutable.isValid)
        #expect(notExecutable.warnings.map(\.code).contains("script-not-executable"))

        let executable = validate { fileSystem in
            addMinimalTemplate(to: fileSystem, at: "/t", substrate: "{ \"kind\": \"script\" }")
            fileSystem.addFile("/t/scripts/provision-workspace", "#!/bin/sh\n", executable: true)
        }
        #expect(executable.isValid)
        #expect(executable.warnings.isEmpty)
    }

    @Test func flagsInvalidPoolSize() {
        let report = validate { fileSystem in
            addMinimalTemplate(to: fileSystem, at: "/t", substrate: "{ \"kind\": \"clone-pool\", \"poolSize\": 0 }")
        }
        #expect(codes(report).contains("invalid-pool-size"))
    }

    @Test func flagsUnknownPlaceholders() {
        let report = validate { fileSystem in
            addMinimalTemplate(to: fileSystem, at: "/t")
            fileSystem.addFile("/t/prompts/task.md", "{{task}} but also {{surprise}}")
        }
        #expect(codes(report).contains("unknown-placeholder"))
        #expect(!report.isValid)
    }

    @Test func parameterPlaceholdersAreAllowedInPrompts() {
        let report = validate { fileSystem in
            addMinimalTemplate(to: fileSystem, at: "/t")
            fileSystem.addFile("/t/prompts/task.md", "{{task}} in {{repo_root}}")
        }
        #expect(report.isValid, "unexpected findings: \(report.findings)")
    }

    @Test func flagsSecretMaterial() {
        let report = validate { fileSystem in
            addMinimalTemplate(to: fileSystem, at: "/t")
            fileSystem.addFile("/t/scripts/setup", "export GITHUB_TOKEN=ghp_abc123def456")
        }
        let secretFindings = report.findings.filter { $0.code == "secret-material" }
        #expect(secretFindings.count == 1)
        #expect(secretFindings.first?.path == "scripts/setup")
        #expect(!report.isValid)
    }

    @Test func invalidLayoutJSONIsAnError() {
        let report = validate { fileSystem in
            addMinimalTemplate(
                to: fileSystem,
                at: "/t",
                extra: ",\n  \"layout\": \"layouts/task.json\""
            )
            fileSystem.addFile("/t/layouts/task.json", "not json")
        }
        #expect(codes(report).contains("invalid-layout"))
    }
}
