import Foundation
import Testing
@testable import CmuxOrchestration

@Suite struct OrchestrationRunPlannerTests {
    private struct Fixture {
        let fileSystem = InMemoryFileSystem()
        let planner: OrchestrationRunPlanner
        var installation: InstalledOrchestration

        init(
            substrate: String = "{ \"kind\": \"worktree\" }",
            extra: String = "",
            resolvedParameters: [String: OrchestrationParameterValue] = [
                "repo_root": .string("/repos/proj"),
                "concurrency": .int(2),
            ]
        ) throws {
            addMinimalTemplate(to: fileSystem, at: "/i/template", substrate: substrate, extra: extra)
            let manifest = try OrchestrationManifest.parse(
                data: fileSystem.readData(atPath: "/i/template/orchestration.json")
            ).manifest
            planner = OrchestrationRunPlanner(fileSystem: fileSystem)
            installation = InstalledOrchestration(
                manifest: manifest,
                record: OrchestrationInstallRecord(
                    name: manifest.name,
                    source: .localPath("/src"),
                    installedAt: Date(timeIntervalSince1970: 0),
                    templateVersion: manifest.version,
                    resolvedParameters: resolvedParameters
                ),
                templateDirectory: "/i/template"
            )
        }

        func request(
            tasks: [OrchestrationTaskInput],
            overrides: [String: OrchestrationParameterValue] = [:],
            agentID: String? = nil,
            cmuxVersion: OrchestrationVersion? = nil
        ) -> OrchestrationRunPlanner.Request {
            OrchestrationRunPlanner.Request(
                installation: installation,
                tasks: tasks,
                parameterOverrides: overrides,
                agentID: agentID,
                runID: "a1b2c3d4e5",
                cmuxVersion: cmuxVersion,
                homeDirectory: "/home"
            )
        }
    }

    @Test func plansWorktreeWorkspaces() throws {
        let fixture = try Fixture()
        let plan = try fixture.planner.plan(fixture.request(tasks: [
            OrchestrationTaskInput(title: "Fix flaky test"),
        ]))

        #expect(plan.orchestrationName == "demo-fleet")
        #expect(plan.groupName == "demo-fleet · a1b2c3")
        #expect(plan.agentID == "claude")
        #expect(plan.workspaceRoot == "/repos/proj/.cmux/orchestrations/demo-fleet")
        #expect(plan.workspaces.count == 1)

        let workspace = plan.workspaces[0]
        #expect(workspace.title == "demo-fleet 1: Fix flaky test")
        #expect(workspace.directory == "/repos/proj/.cmux/orchestrations/demo-fleet/a1b2c3-t1-fix-flaky-test")
        #expect(workspace.branch == "demo-fleet/a1b2c3-t1-fix-flaky-test")
        #expect(workspace.provision == .gitWorktree(repoRoot: "/repos/proj", branch: "demo-fleet/a1b2c3-t1-fix-flaky-test"))
        #expect(workspace.env["CMUX_ORCHESTRATION"] == "demo-fleet")
        #expect(workspace.env["CMUX_ORCHESTRATION_TASK"] == "1")

        // Prompt file carries the rendered prompt; command embeds it quoted.
        #expect(workspace.filesToWrite.count == 1)
        let promptFile = workspace.filesToWrite[0]
        #expect(promptFile.relativePath == ".cmux/orchestration-prompt.md")
        #expect(promptFile.contents.contains("Fix flaky test"))
        #expect(promptFile.contents.contains(workspace.directory))
        #expect(workspace.commandText.hasPrefix("claude '"))
        #expect(workspace.commandText.contains("Fix flaky test"))
    }

    @Test func concurrencyParameterCapsTasksWithNote() throws {
        let fixture = try Fixture()
        let plan = try fixture.planner.plan(fixture.request(tasks: [
            OrchestrationTaskInput(title: "one"),
            OrchestrationTaskInput(title: "two"),
            OrchestrationTaskInput(title: "three"),
        ]))
        #expect(plan.workspaces.count == 2)
        #expect(plan.notes.contains { $0.contains("concurrency") })
    }

    @Test func parameterOverridesWinAndMissingParametersFail() throws {
        var fixture = try Fixture(resolvedParameters: ["concurrency": .int(2)])
        #expect(throws: OrchestrationPlanError.self) {
            try fixture.planner.plan(fixture.request(tasks: [OrchestrationTaskInput(title: "x")]))
        }

        let plan = try fixture.planner.plan(fixture.request(
            tasks: [OrchestrationTaskInput(title: "x")],
            overrides: ["repo_root": .string("~/proj")]
        ))
        #expect(plan.workspaceRoot == "/home/proj/.cmux/orchestrations/demo-fleet")
        fixture.installation.record.resolvedParameters = [:]
    }

    @Test func emptyTasksFail() throws {
        let fixture = try Fixture()
        #expect(throws: OrchestrationPlanError.self) {
            try fixture.planner.plan(fixture.request(tasks: []))
        }
    }

    @Test func minCmuxVersionGate() throws {
        let fixture = try Fixture(extra: ",\n  \"minCmuxVersion\": \"1.5\"")
        #expect(throws: OrchestrationPlanError.self) {
            try fixture.planner.plan(fixture.request(
                tasks: [OrchestrationTaskInput(title: "x")],
                cmuxVersion: OrchestrationVersion(string: "1.4.9")
            ))
        }
        // Equal and newer versions pass; nil skips the gate.
        _ = try fixture.planner.plan(fixture.request(
            tasks: [OrchestrationTaskInput(title: "x")],
            cmuxVersion: OrchestrationVersion(string: "1.5.0")
        ))
        _ = try fixture.planner.plan(fixture.request(tasks: [OrchestrationTaskInput(title: "x")]))
    }

    @Test func agentOverrideMustExist() throws {
        let fixture = try Fixture()
        #expect(throws: OrchestrationPlanError.self) {
            try fixture.planner.plan(fixture.request(
                tasks: [OrchestrationTaskInput(title: "x")],
                agentID: "ghost"
            ))
        }
    }

    @Test func clonePoolPlansClones() throws {
        let fixture = try Fixture(substrate: "{ \"kind\": \"clone-pool\", \"poolSize\": 2 }")
        let plan = try fixture.planner.plan(fixture.request(tasks: [OrchestrationTaskInput(title: "x")]))
        guard case .gitClone(let repoRoot, _) = plan.workspaces[0].provision else {
            Issue.record("expected gitClone provision")
            return
        }
        #expect(repoRoot == "/repos/proj")
    }

    @Test func scriptSubstratePlansScriptAndDefaultsWorkspaceRootToHome() throws {
        let fixture = try Fixture(substrate: "{ \"kind\": \"script\", \"provision\": \"scripts/up\" }")
        fixture.fileSystem.addFile("/i/template/scripts/up", "#!/bin/sh", executable: true)
        let plan = try fixture.planner.plan(fixture.request(tasks: [OrchestrationTaskInput(title: "x")]))
        #expect(plan.workspaceRoot == "/home/.cmuxterm/orchestrations/demo-fleet/workspaces")
        #expect(plan.workspaces[0].provision == .script(scriptPath: "/i/template/scripts/up"))
        #expect(plan.trust.scriptPaths == ["scripts/up"])
        #expect(plan.trust.substrate == .script)
    }

    @Test func stepsUseFirstStepWithNote() throws {
        let extra = """
        ,
          "steps": [
            { "id": "plan", "agent": "claude", "prompt": "prompts/plan.md" },
            { "id": "code", "agent": "claude", "prompt": "prompts/task.md" }
          ]
        """
        let fixture = try Fixture(extra: extra)
        fixture.fileSystem.addFile("/i/template/prompts/plan.md", "PLAN {{task}}")
        let plan = try fixture.planner.plan(fixture.request(tasks: [OrchestrationTaskInput(title: "x")]))
        #expect(plan.workspaces[0].filesToWrite[0].contents == "PLAN x")
        #expect(plan.notes.contains { $0.contains("first step") })
    }

    @Test func issueNumberAndBodyRenderIntoPrompt() throws {
        let fixture = try Fixture()
        fixture.fileSystem.addFile("/i/template/prompts/task.md", "#{{issue_number}}: {{task}}")
        let plan = try fixture.planner.plan(fixture.request(tasks: [
            OrchestrationTaskInput(title: "Fix it", body: "Details here", issueNumber: 42),
        ]))
        let prompt = plan.workspaces[0].filesToWrite[0].contents
        #expect(prompt == "#42: Fix it\n\nDetails here")
    }

    @Test func layoutJSONIsPassedThrough() throws {
        let fixture = try Fixture(extra: ",\n  \"layout\": \"layouts/task.json\"")
        fixture.fileSystem.addFile("/i/template/layouts/task.json", "{\"layout\":{\"type\":\"terminal\"}}")
        let plan = try fixture.planner.plan(fixture.request(tasks: [OrchestrationTaskInput(title: "x")]))
        #expect(plan.workspaces[0].layoutJSON == "{\"layout\":{\"type\":\"terminal\"}}")
    }

    @Test func shellQuotingSurvivesHostileTaskTitles() throws {
        let fixture = try Fixture()
        let plan = try fixture.planner.plan(fixture.request(tasks: [
            OrchestrationTaskInput(title: "don't; rm -rf $(HOME) `x`"),
        ]))
        let command = plan.workspaces[0].commandText
        // The prompt is single-quoted; the embedded single quote is escaped
        // so the command never leaves the quoted region.
        #expect(command.contains("'\\''"))
        #expect(command.hasPrefix("claude '"))
    }

    @Test func trustFingerprintTracksTrustMaterial() throws {
        let fixture = try Fixture()
        let plan = try fixture.planner.plan(fixture.request(tasks: [OrchestrationTaskInput(title: "x")]))
        let same = try fixture.planner.plan(fixture.request(tasks: [OrchestrationTaskInput(title: "y")]))
        // Deterministic across runs and independent of task inputs.
        #expect(plan.trust.fingerprint == same.trust.fingerprint)
        #expect(plan.trust.fingerprint.count == 64)

        var changed = plan.trust
        changed.agentCommands = ["claude: claude --dangerously-skip-permissions {{prompt}}"]
        #expect(changed.fingerprint != plan.trust.fingerprint)

        var versionBump = plan.trust
        versionBump.templateVersion = "9.9.9"
        #expect(versionBump.fingerprint != plan.trust.fingerprint)
    }

    @Test func trustFingerprintTracksPromptContent() throws {
        let fixture = try Fixture()
        let before = try fixture.planner.plan(fixture.request(tasks: [OrchestrationTaskInput(title: "x")]))
        // A content-only edit (same paths, commands, version) must change
        // the fingerprint so a pending confirmation is invalidated.
        fixture.fileSystem.addFile("/i/template/prompts/task.md", "Do this instead: {{task}}")
        let after = try fixture.planner.plan(fixture.request(tasks: [OrchestrationTaskInput(title: "x")]))
        #expect(after.trust.contentDigest != before.trust.contentDigest)
        #expect(after.trust.fingerprint != before.trust.fingerprint)
    }

    @Test func planIsCodable() throws {
        let fixture = try Fixture()
        let plan = try fixture.planner.plan(fixture.request(tasks: [OrchestrationTaskInput(title: "x")]))
        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(OrchestrationRunPlan.self, from: data)
        #expect(decoded == plan)
    }
}

@Suite struct OrchestrationScaffoldTests {
    @Test func scaffoldedTemplateValidatesCleanly() throws {
        let fileSystem = InMemoryFileSystem()
        let scaffold = OrchestrationScaffold(fileSystem: fileSystem)
        try scaffold.scaffold(name: "my-fleet", directory: "/new")

        let report = OrchestrationValidator(fileSystem: fileSystem).validate(templateDirectory: "/new")
        #expect(report.isValid, "unexpected findings: \(report.findings)")
        #expect(report.manifest?.name == "my-fleet")
        #expect(report.warnings.isEmpty)
    }

    @Test func scaffoldRefusesExistingManifestAndBadNames() throws {
        let fileSystem = InMemoryFileSystem()
        let scaffold = OrchestrationScaffold(fileSystem: fileSystem)
        try scaffold.scaffold(name: "my-fleet", directory: "/new")

        #expect(throws: OrchestrationManifestError.self) {
            try scaffold.scaffold(name: "my-fleet", directory: "/new")
        }
        #expect(throws: OrchestrationManifestError.self) {
            try scaffold.scaffold(name: "Bad Name", directory: "/other")
        }
    }
}
