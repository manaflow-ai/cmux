import Foundation
import Testing
@testable import CmuxOrchestration

/// The first-party example template is the format's living test fixture:
/// it must always validate cleanly and produce a real worktree run plan.
@Suite struct ExampleTemplateTests {
    private static var exampleDirectory: String {
        // …/Packages/macOS/CmuxOrchestration/Tests/CmuxOrchestrationTests/ExampleTemplateTests.swift
        // -> repo root is five directories up from this file's directory.
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<5 {
            url.deleteLastPathComponent()
        }
        return url.appendingPathComponent("Examples/Orchestrations/issue-fleet").path
    }

    @Test func exampleValidatesWithoutFindings() {
        let report = OrchestrationValidator().validate(templateDirectory: Self.exampleDirectory)
        #expect(report.isValid, "example template invalid: \(report.errors.map(\.message))")
        #expect(report.warnings.isEmpty, "example template warnings: \(report.warnings.map(\.message))")
        #expect(report.manifest?.name == "issue-fleet")
    }

    @Test func examplePlansAWorktreeRun() throws {
        let manifest = try OrchestrationManifestParser.parse(
            data: Data(contentsOf: URL(fileURLWithPath: Self.exampleDirectory + "/orchestration.json"))
        ).manifest
        let installation = InstalledOrchestration(
            manifest: manifest,
            record: OrchestrationInstallRecord(
                name: manifest.name,
                source: .localPath(Self.exampleDirectory),
                installedAt: Date(timeIntervalSince1970: 0),
                templateVersion: manifest.version,
                resolvedParameters: [
                    "repo_root": .string("/repos/demo"),
                    "concurrency": .int(2),
                    "base_instructions": .string("Be careful."),
                ]
            ),
            templateDirectory: Self.exampleDirectory
        )
        let plan = try OrchestrationRunPlanner().plan(OrchestrationRunPlanner.Request(
            installation: installation,
            tasks: [
                OrchestrationTaskInput(title: "Fix the flaky scroll test"),
                OrchestrationTaskInput(title: "Add --json to cmux top", issueNumber: 12),
            ],
            runID: "cafe01beef",
            homeDirectory: "/home"
        ))

        #expect(plan.workspaces.count == 2)
        #expect(plan.trust.substrate == .worktree)
        #expect(plan.trust.scriptPaths.isEmpty)
        let first = plan.workspaces[0]
        guard case .gitWorktree(let repoRoot, let branch) = first.provision else {
            Issue.record("expected worktree provision")
            return
        }
        #expect(repoRoot == "/repos/demo")
        #expect(branch.hasPrefix("issue-fleet/"))
        #expect(first.commandText.hasPrefix("claude --permission-mode acceptEdits '"))
        let prompt = first.filesToWrite[0].contents
        #expect(prompt.contains("Fix the flaky scroll test"))
        #expect(prompt.contains("Be careful."))
        // Steps exist, so v1 notes it runs the first step only.
        #expect(plan.notes.contains { $0.contains("first step") })
    }
}
