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

    @Test("enforces multiple and pattern-property constraints")
    func enforcesRemainingSchemaKeywords() throws {
        let invalidMagnification = try issues(
            ["app": ["globalFontMagnification": 105]]
        )
        #expect(
            contains(
                invalidMagnification,
                path: "$.app.globalFontMagnification",
                message: "multiple of 10"
            )
        )

        let validOverrides = try issues([
            "notifications": [
                "soundOverrides": [
                    "codex": [
                        "turnDone": ["sound": "Ping"],
                    ],
                ],
            ],
        ])
        #expect(validOverrides.isEmpty)

        let futureOverrideField = try issues([
            "schemaVersion": 2,
            "notifications": [
                "soundOverrides": [
                    "codex": [
                        "turnDone": [
                            "sound": "Ping",
                            "futureFieldA": true,
                            "futureFieldB": 1,
                            "futureFieldC": "kept",
                        ],
                    ],
                ],
            ],
        ])
        #expect(futureOverrideField.isEmpty)

        let invalidOverride = try issues([
            "notifications": [
                "soundOverrides": [
                    "codex": [
                        "turnDone": ["sound": "laser"],
                    ],
                ],
            ],
        ])
        #expect(
            contains(
                invalidOverride,
                path: "$.notifications.soundOverrides.codex.turnDone.sound",
                message: "must be one of"
            )
        )
    }

    @Test("rejects large values that are not exact multiples")
    func rejectsLargeNonMultiple() throws {
        let validator = CmuxConfigSemanticValidator(scope: .global)
        let result = validator.validateObject(
            ["width": 100_000_000_001],
            schema: [
                "type": "object",
                "properties": ["width": ["type": "number", "multipleOf": 20]],
                "additionalProperties": false,
            ],
            path: "$",
            tolerateUnknownProperties: false
        )
        #expect(contains(result, path: "$.width", message: "must be a multiple of 20"))
    }

    @Test("future schema versions tolerate unknown additions but still validate known fields")
    func futureSchemaCompatibility() throws {
        let futureExtension = try issues([
            "schemaVersion": 2,
            "futureSection": ["newKey": true],
            "app": ["appearance": "dark"],
        ])
        #expect(futureExtension.isEmpty)

        let invalidKnownField = try issues([
            "schemaVersion": 2,
            "futureSection": ["newKey": true],
            "app": ["appearance": "neon"],
        ])
        #expect(
            contains(
                invalidKnownField,
                path: "$.app.appearance",
                message: "must be one of"
            )
        )
    }

    @Test("future additions do not consume the known notification event limit")
    func futureNotificationEvent() throws {
        let events: [String: Any] = [
            "turnDone": ["sound": "Ping"],
            "needsInput": ["sound": "Ping"],
            "errorStalled": ["sound": "Ping"],
            "futureEvent": ["newOption": true],
        ]
        let future = try issues([
            "schemaVersion": 2,
            "notifications": ["soundOverrides": ["codex": events]],
        ])
        #expect(future.isEmpty)
        let current = try issues([
            "schemaVersion": 1,
            "notifications": ["soundOverrides": ["codex": events]],
        ])
        #expect(contains(current, path: "$.notifications.soundOverrides.codex", message: "at most 3"))
        #expect(contains(current, path: "$.notifications.soundOverrides.codex.futureEvent", message: "unknown"))
    }

    @Test("shortcut binding ids are validated even with value schemas")
    func shortcutBindingIdsAreValidated() {
        let validator = CmuxConfigSemanticValidator(scope: .global)
        let result = validator.validateObject(
            ["newWindwo": "cmd-n"],
            schema: [
                "type": "object",
                "propertyNames": ["enum": ["newWindow"]],
                "additionalProperties": ["type": "string"],
            ],
            path: "$.shortcuts.bindings",
            tolerateUnknownProperties: false
        )
        #expect(contains(result, path: "$.shortcuts.bindings.newWindwo", message: "must be one of"))
    }

    @Test("open dictionary constraints apply to all keys in current and future schemas", arguments: [false, true])
    func openDictionaryConstraints(tolerateUnknown: Bool) {
        let validator = CmuxConfigSemanticValidator(scope: .global)
        let result = validator.validateObject(
            ["valid": "text", "invalid name": "text"],
            schema: [
                "maxProperties": 1,
                "propertyNames": ["pattern": "^[a-z]+$"],
                "additionalProperties": ["type": "string"],
            ],
            path: "$",
            tolerateUnknownProperties: tolerateUnknown
        )
        #expect(contains(result, path: "$", message: "at most 1"))
        #expect(contains(result, path: "$['invalid name']", message: "must match"))
    }

    @Test("closed future additions bypass name constraints but known fields stay validated")
    func closedFutureDictionaryConstraints() {
        let validator = CmuxConfigSemanticValidator(scope: .global)
        let schema: [String: Any] = [
            "maxProperties": 1,
            "propertyNames": ["pattern": "^[a-z]+$"],
            "additionalProperties": false,
            "properties": ["known": ["type": "boolean"]],
        ]
        let value: [String: Any] = ["known": "invalid", "future name": 1]
        let current = validator.validateObject(value, schema: schema, path: "$", tolerateUnknownProperties: false)
        #expect(contains(current, path: "$", message: "at most 1"))
        #expect(contains(current, path: "$['future name']", message: "must match"))
        let future = validator.validateObject(value, schema: schema, path: "$", tolerateUnknownProperties: true)
        #expect(future.count == 1)
        #expect(contains(future, path: "$.known", message: "expected boolean"))
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
