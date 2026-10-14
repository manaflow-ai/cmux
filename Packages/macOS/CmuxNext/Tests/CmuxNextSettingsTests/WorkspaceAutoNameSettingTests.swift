import CmuxNextSettings
import Foundation
import Testing

/// `workspaces.autoName` (hq#1957): on by default, so a workspace the user
/// never named takes its front tab's name; off turns that off. The default
/// the app reads, the Settings row's default and docs/configuration.md agree.
struct WorkspaceAutoNameSettingTests {
    private static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["workspaces": .object(["autoName": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func onWhenUnset() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.sidebarSections.autoNamesWorkspaces)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func falseTurnsItOff() {
        #expect(!Self.parse(.bool(false)).sidebarSections.autoNamesWorkspaces)
        #expect(Self.parse(.bool(true)).sidebarSections.autoNamesWorkspaces)
    }

    @Test func aBadValueKeepsTheDefaultAndSaysWhy() {
        let snapshot = Self.parse(.string("yes"))
        #expect(snapshot.sidebarSections.autoNamesWorkspaces)
        #expect(snapshot.diagnostics.contains { $0.path == "workspaces.autoName" })
    }

    @Test func settingsRowDefaultMatchesTheAppAndTheDocs() throws {
        let row = try #require(SettingsSchema.descriptor(for: ["workspaces", "autoName"]))
        #expect(row.defaultValue == .bool(true))
        #expect(SettingsSchema.agentSettableKeys.contains("workspaces.autoName"))
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        let docs = try String(contentsOf: url.appending(path: "docs/configuration.md"), encoding: .utf8)
        let section = try #require(docs.components(separatedBy: "## `workspaces.autoName`").dropFirst().first)
            .components(separatedBy: "\n## ").first ?? ""
        #expect(section.contains("\"autoName\": true"))
        #expect(section.contains("- `true` (default)"))
    }
}
