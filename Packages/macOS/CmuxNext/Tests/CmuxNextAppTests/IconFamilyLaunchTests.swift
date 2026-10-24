@testable import CmuxNextApp
import CmuxNextDesign
import Foundation
import Testing

/// Native icons load once, before the tunable store finishes reading its file off the main actor, so
/// launch reads `icons.family` from the file itself (Lucas 2026-10-17: the custom family never showed).
struct IconFamilyLaunchTests {
    private func file(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "icon-family-\(UUID().uuidString).json")
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func launchReadsTheFamilyFromTheFile() throws {
        let url = try file(#"{"version": 1, "values": {"icons.family": "custom"}}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(DebugSettingsService.launchIconFamily(url) == .custom)
    }

    @Test func noFileOrNoValueIsThePack() throws {
        #expect(DebugSettingsService.launchIconFamily(nil) == .pack)
        let url = try file(#"{"version": 1, "values": {}}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(DebugSettingsService.launchIconFamily(url) == .pack)
    }
}
