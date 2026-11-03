import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

@MainActor @Suite(.serialized) struct SettingsPageRowsTests {
    @Test func rawPreferenceAndManagedMetadataSurviveThePageBridge() async throws {
        let key = "agentPane.display.harnessPlacement"
        let path = ["agentPane", "display", "harnessPlacement"]
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-placement-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appending(path: "cmux-next.json")
        for managed in [false, true] {
            try Data("{}".utf8).write(to: url)
            let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                              managedReader: FixedManagedPreferenceReader(ManagedPreferences(forced: managed ? [key: "top"] : [:])),
                                              managedWatchFiles: [])
            await settings.reload()
            func rows() -> [JSONValue] {
                settings.pageRows(section: nil) { source in
                    switch source {
                    case .device: ["source": "device"]
                    case .team: ["source": "team"]
                    }
                }.arrayValue ?? []
            }
            func row() throws -> JSONValue { try #require(rows().first { $0["key"] == .string(key) }) }
            #expect(try row()["stored"] == .null)
            #expect(try row()["value"] == .string(managed ? "top" : "symbols"))
            #expect(try row()["managed"] == (managed ? .object(["source": .string("device")]) : .null))
            if !managed {
                try await settings.setSetting(at: path, to: "symbols", by: .caller("mcp"))
                #expect(try row()["stored"] == "symbols")
                #expect(try row()["value"] == "symbols")
                try await settings.setSetting(at: path, to: nil, by: .user)
                #expect(try row()["stored"] == .null)
            }
            let roots = try #require(rows().first { $0["key"] == "agents.chats.roots" })
            #expect(roots["folders"] == settings.chatRootRows)
            #expect(roots["user_roots"] == (settings.fileRoot.value(at: ChatSettings.rootsPath) ?? .array([])))
        }
    }
}
