import Foundation
import XCTest
@testable import CMUXClaudeNotifications

final class ClaudeNotificationsTests: XCTestCase {
    func testNotificationTypeNormalizationIsCaseAndSeparatorInsensitive() {
        XCTAssertEqual(
            ClaudeNotificationTypeNormalization.normalizedUniqueList([
                " idle prompt ",
                "IDLE-PROMPT",
                "permission_prompt",
                "",
            ]),
            ["idle_prompt", "permission_prompt"]
        )
    }

    func testNotificationTypeExtractionUsesNotificationPayloadTypesOnlyForGenericTypeKeys() {
        let root: [String: Any] = [
            "hook_event_name": "Notification",
            "type": "notification",
            "notification": [
                "type": "idle_prompt",
                "kind": "permission_prompt",
            ],
            "data": "{\"reason\":\"tool_use\"}",
        ]

        XCTAssertEqual(
            Set(ClaudeNotificationTypeExtractor.values(inJSONValue: root)),
            Set(["idle_prompt", "permission_prompt", "tool_use"])
        )
    }

    func testCurrentInvalidSettingsFileWinsAsEmptySuppressionSet() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let primary = directory.appendingPathComponent("cmux.json")
        let legacy = directory.appendingPathComponent("settings.json")
        try "{".write(to: primary, atomically: true, encoding: .utf8)
        try #"{"notifications":{"ignoredClaudeNotificationTypes":["idle_prompt"]}}"#
            .write(to: legacy, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            ClaudeIgnoredNotificationSettings.ignoredTypesFromSettingsFiles(
                paths: [primary.path, legacy.path]
            ),
            []
        )
    }

    func testCurrentMissingSettingWinsAsEmptySuppressionSet() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let primary = directory.appendingPathComponent("cmux.json")
        let legacy = directory.appendingPathComponent("settings.json")
        try #"{"notifications":{}}"#.write(to: primary, atomically: true, encoding: .utf8)
        try #"{"notifications":{"ignoredClaudeNotificationTypes":["idle_prompt"]}}"#
            .write(to: legacy, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            ClaudeIgnoredNotificationSettings.ignoredTypesFromSettingsFiles(
                paths: [primary.path, legacy.path]
            ),
            []
        )
    }

    func testMissingSettingsFilesReturnNilForEnvironmentFallback() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertNil(
            ClaudeIgnoredNotificationSettings.ignoredTypesFromSettingsFiles(
                paths: [directory.appendingPathComponent("missing.json").path]
            )
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-notifications-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
