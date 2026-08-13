import CmuxAgentChat
import Foundation
import Testing
@testable import CmuxMobileShellUI

@MainActor
@Suite struct AgentFeedVariantTests {
    @Test func exposesExactlyFivePersistableCompositions() {
        #expect(AgentFeedVariant.allCases.count == 5)
        #expect(Set(AgentFeedVariant.allCases.map(\.rawValue)).count == 5)
        #expect(AgentFeedVariant.allCases.allSatisfy { !$0.title.isEmpty && !$0.subtitle.isEmpty })
    }

    @Test func fixtureCoversEveryCodingPrimitiveAndAttentionState() {
        let store = AgentFeedStore.fixture()
        let messages = store.entries.compactMap(\.message)
        let kinds = Set(messages.map { kindName($0.kind) })

        #expect(kinds == Set([
            "prose", "thought", "toolUse", "terminal", "fileEdit",
            "permissionRequest", "question", "status", "attachment", "unsupported",
        ]))
        #expect(store.entries.contains(where: { $0.requiresReply && $0.isPresence }))
        #expect(store.entries.contains(where: { $0.terminalBlock != nil }))
        #expect(store.attentionCount == 1)
    }

    @Test func fixtureReloadRebuildsStableIDs() {
        let store = AgentFeedStore.fixture()
        let firstIDs = store.entries.map(\.id)
        store.loadFixture()
        #expect(store.entries.map(\.id) == firstIDs)
    }

    #if DEBUG
    @Test func labSelectionPersistsAcrossDisplaySettingsInstances() throws {
        let suiteName = "AgentFeedVariantTests.settings"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let settings = MobileDisplaySettings(defaults: defaults)
        settings.agentFeedVariant = .prism
        #expect(MobileDisplaySettings(defaults: defaults).agentFeedVariant == .prism)
    }
    #endif

    private func kindName(_ kind: ChatMessageKind) -> String {
        switch kind {
        case .prose: "prose"
        case .thought: "thought"
        case .toolUse: "toolUse"
        case .terminal: "terminal"
        case .fileEdit: "fileEdit"
        case .permissionRequest: "permissionRequest"
        case .question: "question"
        case .status: "status"
        case .attachment: "attachment"
        case .unsupported: "unsupported"
        }
    }
}
