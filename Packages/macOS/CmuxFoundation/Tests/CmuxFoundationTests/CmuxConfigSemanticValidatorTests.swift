import Foundation
import Testing
@testable import CmuxFoundation

@Suite("cmux semantic config validation")
struct CmuxConfigSemanticValidatorTests {
    private func issues(
        _ object: Any,
        scope: CmuxConfigSemanticScope = .global
    ) throws -> [CmuxConfigSemanticIssue] {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try CmuxConfigSemanticValidator(scope: scope).validate(jsonData: data)
    }

    private func contains(
        _ issues: [CmuxConfigSemanticIssue],
        path: String,
        message: String
    ) -> Bool {
        issues.contains { issue in
            issue.path == path && issue.message.contains(message)
        }
    }

    @Test("accepts valid settings and preserved config sections")
    func acceptsValidConfig() throws {
        let result = try issues([
            "schemaVersion": 1,
            "app": ["appearance": "dark"],
            "fileEditor": ["tabWidth": 4],
            "rightSidebar": ["width": 320],
        ])
        #expect(result.isEmpty)
    }

    @Test("reports unknown paths, types, enums, bounds, and nested constraints")
    func reportsSemanticFailures() throws {
        let cases: [(Any, String, String)] = [
            (["app": ["madeUpSetting": true]], "$.app.madeUpSetting", "unknown configuration key"),
            (["notifications": ["dockBadge": "yes"]], "$.notifications.dockBadge", "expected boolean"),
            (["app": ["appearance": "neon"]], "$.app.appearance", "must be one of"),
            (["fileEditor": ["tabWidth": 0]], "$.fileEditor.tabWidth", "must be >= 1"),
            (["agentChat": ["fonts": ["baseSize": 0]]], "$.agentChat.fonts.baseSize", "must be > 0"),
            (["commands": "echo hello"], "$.commands", "expected array"),
        ]

        for (object, path, message) in cases {
            let result = try issues(object)
            #expect(contains(result, path: path, message: message))
        }
    }

    @Test("project scope rejects global settings while keeping project hooks legal")
    func enforcesProjectScope() throws {
        let globalOnly = try issues(
            ["app": ["appearance": "system"]],
            scope: .project
        )
        #expect(contains(globalOnly, path: "$.app", message: "global cmux.json"))

        let hooks = try issues(
            ["notifications": ["hooksMode": "replace", "hooks": []]],
            scope: .project
        )
        #expect(hooks.isEmpty)

        let workspacePlacement = try issues(
            ["workspaceGroups": ["newWorkspacePlacement": "top"]],
            scope: .project
        )
        #expect(
            contains(
                workspacePlacement,
                path: "$.workspaceGroups.newWorkspacePlacement",
                message: "global cmux.json"
            )
        )
    }
}
