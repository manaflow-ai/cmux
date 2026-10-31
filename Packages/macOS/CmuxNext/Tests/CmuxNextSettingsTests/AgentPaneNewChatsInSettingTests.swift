import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// `agentPane.newChatsIn` (Settings > Agent Chat > Start New Chats In): where a new chat runs when
/// its composer picks nothing, this Mac by default (Leo turns Cloud on himself). It reaches the page
/// on the `composer` event (webviews composerSettings.ts, runLocationDefault.ts).
@MainActor @Suite(.serialized) struct AgentPaneNewChatsInSettingTests {
    @Test func thisMacByDefaultAndOnThePage() {
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(snapshot.agentPaneComposer.newChatsIn == .local)
        #expect(snapshot.agentPaneComposer.pageValue.value(at: ["newChatsIn"])?.stringValue == "local")
        let row = SettingsSchema.descriptor(for: AgentPaneComposerSetting.newChatsInPath)
        #expect(row?.defaultValue == .string("local"))
        #expect(row?.section == .general)
    }

    @Test func cloudRoundTrips() {
        let root = JSONValue.object(["agentPane": .object(["newChatsIn": .string("cloud")])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.agentPaneComposer.newChatsIn == .cloud)
        #expect(snapshot.agentPaneComposer.pageValue.value(at: ["newChatsIn"])?.stringValue == "cloud")
        #expect(!snapshot.diagnostics.contains { $0.path == "agentPane.newChatsIn" })
    }

    @Test func aBadValueIsThisMacWithADiagnostic() {
        for bad: JSONValue in [.string("Cloud"), .string("vm"), .bool(true)] {
            let root = JSONValue.object(["agentPane": .object(["newChatsIn": bad])])
            let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
            #expect(snapshot.agentPaneComposer.newChatsIn == .local)
            #expect(snapshot.diagnostics.contains { $0.path == "agentPane.newChatsIn" })
        }
    }

    /// An agent may set it (`cmux settings set agentPane.newChatsIn cloud` runs as a cli writer),
    /// so a lane can turn on Cloud first send in a DEV build and prove it.
    @Test func anAgentSetsItThroughTheSettingsWritePath() async throws {
        #expect(SettingsSchema.agentSettableKeys.contains("agentPane.newChatsIn"))
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-new-chats-in-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appending(path: "cmux-next.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: .standard(), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()),
                                          managedWatchFiles: [])
        await settings.reload()

        for writer in [SettingWriter.caller("cli"), .caller("mcp")] {
            try await settings.setSetting(at: AgentPaneComposerSetting.newChatsInPath, to: .string("cloud"), by: writer)
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            #expect((saved?["agentPane"] as? [String: Any])?["newChatsIn"] as? String == "cloud")
            try await settings.setSetting(at: AgentPaneComposerSetting.newChatsInPath, to: .string("local"), by: writer)
        }
        await #expect(throws: SettingRefused.self) {
            try await settings.setSetting(at: AgentPaneComposerSetting.newChatsInPath, to: .string("vm"), by: .caller("cli"))
        }
    }
}
