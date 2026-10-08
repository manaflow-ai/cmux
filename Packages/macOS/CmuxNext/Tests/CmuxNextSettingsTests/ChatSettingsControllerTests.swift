import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

@MainActor @Suite struct ChatSettingsControllerTests {
    @Test func managedRootsStayLockedWhileTheUserListCanChange() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "chat-settings-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "cmux.json")
        try Data(#"{"agents":{"chats":{"roots":["/opt/user","relative"]}}}"#.utf8).write(to: file)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: file,
            managedReader: FixedManagedPreferenceReader(.init(forced: ["agents.chats.roots": ["/opt/managed"]])), managedWatchFiles: [])
        await settings.reload()
        let rows = try #require(settings.chatRootRows.arrayValue)
        #expect(rows.first { $0["path"] == "relative" }?["reason"]?.stringValue?.isEmpty == false)
        #expect(rows.first { $0["path"] == "/opt/managed" }?["managed"] == true)
        #expect(settings.chatSettings.roots == ["/opt/user"])
        #expect(settings.chatSettings.managedRoots == ["/opt/managed"])
        try await settings.setSetting(at: ChatSettings.rootsPath, to: ["/opt/replacement"], by: .user)
        #expect(settings.chatSettings.roots == ["/opt/replacement"])
        #expect(settings.chatSettings.managedRoots == ["/opt/managed"])
        #expect(try await settings.file.value(at: ChatSettings.rootsPath) == ["/opt/replacement"])
        await #expect(throws: SettingRefused.self) {
            try await settings.setSetting(at: ChatSettings.rootsPath, to: ["relative"], by: .user)
        }
        await #expect(throws: SettingUserOnly.self) {
            try await settings.setSetting(at: ChatSettings.rootsPath, to: [], by: .caller("mcp"))
        }
        #expect(settings.chatSettings.roots == ["/opt/replacement"])
    }
}
