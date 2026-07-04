import Foundation
import Testing
@testable import CmuxDockExtensions

@Suite("DockExtensionManifest parsing")
struct DockExtensionManifestParsingTests {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    private let validManifest = """
    {
        "$schema": "https://example.com/schema.json",
        "manifestVersion": 1,
        "id": "token-usage",
        "name": "Token Usage",
        "version": "0.1.0",
        "description": "Live token spend",
        "minCmuxVersion": "0.30.0",
        "platforms": ["macos"],
        "icon": "chart.bar.xaxis",
        "build": [
            { "command": ["npm", "install", "--omit=dev"] }
        ],
        "panes": [
            {
                "id": "main",
                "title": "Token Usage",
                "command": ["npx", "--yes", "."],
                "env": { "TOKEN_MODE": "live" },
                "cwd": "app"
            },
            {
                "id": "settings",
                "title": "Settings",
                "command": ["./settings.sh"],
                "platforms": ["macos"]
            }
        ]
    }
    """

    @Test func parsesValidManifest() throws {
        let manifest = try DockExtensionManifest.parse(data: data(validManifest))
        #expect(manifest.id == "token-usage")
        #expect(manifest.name == "Token Usage")
        #expect(manifest.version == "0.1.0")
        #expect(manifest.minCmuxVersion == DockExtensionVersion("0.30.0"))
        #expect(manifest.icon == "chart.bar.xaxis")
        #expect(manifest.build.count == 1)
        #expect(manifest.build[0].command == ["npm", "install", "--omit=dev"])
        #expect(manifest.panes.count == 2)
        #expect(manifest.panes[0].env == ["TOKEN_MODE": "live"])
        #expect(manifest.panes[0].cwd == "app")
        #expect(manifest.unknownTopLevelKeys.isEmpty)
        #expect(manifest.appliesToCurrentPlatform)
        #expect(manifest.panesForCurrentPlatform.count == 2)
    }

    @Test func unknownTopLevelKeysAreWarningsNotErrors() throws {
        let json = """
        {
            "manifestVersion": 1,
            "id": "x",
            "name": "X",
            "version": "1",
            "actions": [{"id": "a"}],
            "events": [],
            "panes": [{ "id": "main", "title": "X", "command": ["x"] }]
        }
        """
        let manifest = try DockExtensionManifest.parse(data: data(json))
        #expect(manifest.unknownTopLevelKeys == ["actions", "events"])
    }

    @Test func unknownPaneKeyIsError() {
        let json = """
        {
            "manifestVersion": 1,
            "id": "x",
            "name": "X",
            "version": "1",
            "panes": [{ "id": "main", "title": "X", "command": ["x"], "sneaky": true }]
        }
        """
        #expect(throws: DockExtensionError.self) {
            try DockExtensionManifest.parse(data: data(json))
        }
    }

    @Test func missingRequiredFieldsCollectAllErrors() {
        let json = """
        { "manifestVersion": 1 }
        """
        do {
            _ = try DockExtensionManifest.parse(data: data(json))
            Issue.record("expected manifestInvalid")
        } catch let DockExtensionError.manifestInvalid(issues) {
            #expect(issues.contains { $0.contains("\"id\"") })
            #expect(issues.contains { $0.contains("\"name\"") })
            #expect(issues.contains { $0.contains("\"version\"") })
            #expect(issues.contains { $0.contains("\"panes\"") })
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func rejectsBadExtensionId() {
        let json = """
        {
            "manifestVersion": 1,
            "id": "bad id!",
            "name": "X",
            "version": "1",
            "panes": [{ "id": "main", "title": "X", "command": ["x"] }]
        }
        """
        #expect(throws: DockExtensionError.self) {
            try DockExtensionManifest.parse(data: data(json))
        }
    }

    @Test func rejectsDottedPaneIdAndDuplicates() {
        let dotted = """
        {
            "manifestVersion": 1, "id": "x", "name": "X", "version": "1",
            "panes": [{ "id": "a.b", "title": "X", "command": ["x"] }]
        }
        """
        #expect(throws: DockExtensionError.self) {
            try DockExtensionManifest.parse(data: data(dotted))
        }
        let duplicated = """
        {
            "manifestVersion": 1, "id": "x", "name": "X", "version": "1",
            "panes": [
                { "id": "a", "title": "X", "command": ["x"] },
                { "id": "a", "title": "Y", "command": ["y"] }
            ]
        }
        """
        #expect(throws: DockExtensionError.self) {
            try DockExtensionManifest.parse(data: data(duplicated))
        }
    }

    @Test func rejectsUnsupportedManifestVersion() {
        let json = """
        { "manifestVersion": 2, "id": "x", "name": "X", "version": "1",
          "panes": [{ "id": "a", "title": "X", "command": ["x"] }] }
        """
        #expect(throws: DockExtensionError.unsupportedManifestVersion(2)) {
            try DockExtensionManifest.parse(data: data(json))
        }
    }

    @Test func rejectsBooleanManifestVersion() {
        let json = """
        { "manifestVersion": true, "id": "x", "name": "X", "version": "1",
          "panes": [{ "id": "a", "title": "X", "command": ["x"] }] }
        """
        #expect(throws: DockExtensionError.self) {
            try DockExtensionManifest.parse(data: data(json))
        }
    }

    @Test func rejectsOversizedManifest() {
        let padding = String(repeating: "x", count: DockExtensionManifest.maximumFileSize)
        let json = "{\"description\": \"\(padding)\"}"
        #expect(throws: DockExtensionError.manifestTooLarge(limitBytes: DockExtensionManifest.maximumFileSize)) {
            try DockExtensionManifest.parse(data: data(json))
        }
    }

    @Test func rejectsAbsoluteAndTraversalCwd() {
        for cwd in ["/etc", "~/x", "a/../../b"] {
            let json = """
            { "manifestVersion": 1, "id": "x", "name": "X", "version": "1",
              "panes": [{ "id": "a", "title": "X", "command": ["x"], "cwd": "\(cwd)" }] }
            """
            #expect(throws: DockExtensionError.self, "cwd \(cwd) should be rejected") {
                try DockExtensionManifest.parse(data: data(json))
            }
        }
    }

    @Test func rejectsInvalidEnvKeysAndEmptyCommand() {
        let badEnv = """
        { "manifestVersion": 1, "id": "x", "name": "X", "version": "1",
          "panes": [{ "id": "a", "title": "X", "command": ["x"], "env": { "1BAD": "v" } }] }
        """
        #expect(throws: DockExtensionError.self) {
            try DockExtensionManifest.parse(data: data(badEnv))
        }
        let emptyCommand = """
        { "manifestVersion": 1, "id": "x", "name": "X", "version": "1",
          "panes": [{ "id": "a", "title": "X", "command": [] }] }
        """
        #expect(throws: DockExtensionError.self) {
            try DockExtensionManifest.parse(data: data(emptyCommand))
        }
    }

    @Test func platformFilteringExcludesOtherPlatforms() throws {
        let json = """
        { "manifestVersion": 1, "id": "x", "name": "X", "version": "1",
          "build": [
            { "command": ["make"], "platforms": ["linux"] },
            { "command": ["make", "mac"], "platforms": ["macos"] }
          ],
          "panes": [
            { "id": "a", "title": "A", "command": ["a"], "platforms": ["windows"] },
            { "id": "b", "title": "B", "command": ["b"] }
          ] }
        """
        let manifest = try DockExtensionManifest.parse(data: data(json))
        #expect(manifest.buildStepsForCurrentPlatform.map(\.command) == [["make", "mac"]])
        #expect(manifest.panesForCurrentPlatform.map(\.id) == ["b"])
    }

    @Test func qualifiedPaneIdSplitsOnLastDot() {
        #expect(DockExtensionPane.splitQualifiedId("a.b.main")! == ("a.b", "main"))
        #expect(DockExtensionPane.splitQualifiedId("x.main")! == ("x", "main"))
        #expect(DockExtensionPane.splitQualifiedId("nodot") == nil)
        #expect(DockExtensionPane.splitQualifiedId(".pane") == nil)
        #expect(DockExtensionPane.splitQualifiedId("ext.") == nil)
    }
}
