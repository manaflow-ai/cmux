@testable import CmuxNextSettings
import Foundation
import Testing

/// NIGHTLY and Release share `~/.config/cmux/cmux-next.json`, but each keeps its own cmux tools answer and Computer
/// Use permissions (cmux-config `build_scope`): the app reads its build's file over the shared document, as its daemon
/// and agents do, and every other preference stays the shared file's.
@Suite struct BuildScopedSettingsTests {
    private static let shared: JSONValue = .object([
        "agents": .object(["cmuxMcp": .string("on"), "defaultPermissionMode": .string("plan")]),
        "computerUse": .object(["mode": .string("fullAccess")]),
        "computerUse.deniedApps": .array([.string("Mail")]),
        "appearance": .object(["density": .string("compact")]),
    ])

    @Test func theBuildsValuesReplaceTheSharedOnes() {
        let merged = BuildScopedSettings.overlay(Self.shared, buildText: #"{"agents": {"cmuxMcp": "off"}, "computerUse": {"mode": "approvedApps"}}"#)
        #expect(merged.value(at: ["agents", "cmuxMcp"]) == .string("off"))
        #expect(merged.value(at: ["computerUse", "mode"]) == .string("approvedApps"))
        // The shared file's flat Computer Use key is not this build's.
        #expect(merged["computerUse.deniedApps"] == nil)
        // Every other preference stays shared.
        #expect(merged.value(at: ["agents", "defaultPermissionMode"]) == .string("plan"))
        #expect(merged.value(at: ["appearance", "density"]) == .string("compact"))
    }

    @Test func aBuildWithoutItsFileYetReadsTheSharedValues() {
        #expect(BuildScopedSettings.overlay(Self.shared, buildText: nil) == Self.shared)
        #expect(BuildScopedSettings.overlay(Self.shared, buildText: "not json") == Self.shared)
    }

    @Test func onlyABuildOnTheSharedFileHasOne() {
        let home = URL(fileURLWithPath: "/Users/me")
        let file = "/Users/me/Library/Application Support/cmux-next/builds/com.cmuxterm.app/build-settings.json"
        #expect(BuildScopedSettings.file(environment: [BuildScopedSettings.fileKey: file], home: home)?.path == file)
        #expect(BuildScopedSettings.file(environment: [:], home: home) == nil)
        #expect(BuildScopedSettings.file(environment: [BuildScopedSettings.fileKey: file,
                                                       "CMUX_NEXT_CONFIG_FILE": "/tmp/test.json"], home: home) == nil)
        #expect(BuildScopedSettings.file(environment: [BuildScopedSettings.fileKey: file,
                                                       "CMUX_NEXT_CONFIG_FILE": "/Users/me/.config/cmux/cmux-next.json"],
                                         home: home)?.path == file)
    }
}
