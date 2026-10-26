import CmuxHomeCore
@testable import CmuxNextHome
@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// Rename a Chief and every surface follows (user, 2026-10-24: the chat header said "cloud chief"
/// while the Home list's tile still said "Chief"): the list's tiles take each Chief's own name,
/// keyed by its conversation, the one the other keeps, and "Chief" only where none is set.
@Suite struct ChiefRenameEverywhereTests {
    static let rows = PerChiefAvatarTests.chiefRows([("agent_mux", "Chief"), ("agent_scout01", "Scout")])

    static func titles(_ names: [ConversationID: String]) -> [String: String] {
        let model = HomeSidebarModel(rows: rows, pins: HomePins(), me: PerChiefAvatarTests.me.id, chiefNames: names)
        return Dictionary(uniqueKeysWithValues: (model.pinned + model.rows).map { ($0.id.rawValue, $0.title) })
    }

    @Test func aRenamedChiefsTileTakesItsNameAndTheOtherKeepsItsOwn() {
        #expect(Self.titles([:]) == ["conv_agent_mux": "Chief", "conv_agent_scout01": "Scout"])
        let renamed = Self.titles([ConversationID("conv_agent_mux"): "cloud chief"])
        #expect(renamed == ["conv_agent_mux": "cloud chief", "conv_agent_scout01": "Scout"])
        let again = Self.titles([ConversationID("conv_agent_mux"): "cloud chief", ConversationID("conv_agent_scout01"): "Scout 2"])
        #expect(again == ["conv_agent_mux": "cloud chief", "conv_agent_scout01": "Scout 2"])
        #expect(Self.titles([ConversationID("conv_agent_mux"): "  "])["conv_agent_mux"] == "Chief", "a blank name falls back")
    }

    @Test func aRenamedTilesVoiceOverNameFollows() {
        let model = HomeSidebarModel(rows: Self.rows, pins: HomePins(), me: PerChiefAvatarTests.me.id,
                                     chiefNames: [ConversationID("conv_agent_mux"): "cloud chief"])
        let tile = (model.pinned + model.rows).first { $0.id.rawValue == "conv_agent_mux" }
        #expect(tile?.accessibilityLabel.hasPrefix("cloud chief") == true)
    }
}
