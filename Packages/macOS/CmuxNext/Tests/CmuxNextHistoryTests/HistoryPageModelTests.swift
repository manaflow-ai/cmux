import CmuxNextHistory
import Foundation
import Testing

struct HistoryPageModelTests {
    static func page(_ id: String, ago: TimeInterval) -> HistoryEntry {
        HistoryEntry(id: id, kind: .page, time: Date().addingTimeInterval(-ago), title: id,
                     payload: .page(url: "https://\(id).example", profile: "default"))
    }

    @Test func filtersMapToKinds() {
        #expect(HistoryPageModel.Filter.all.kinds.isEmpty)
        #expect(HistoryPageModel.Filter.agents.kinds == [.agent])
    }

    @Test func applyGroupsAndSelectionMoves() {
        let model = HistoryPageModel()
        model.apply([Self.page("a", ago: 10), Self.page("b", ago: 20), Self.page("c", ago: 3 * 86_400)])
        #expect(model.flatEntries.map(\.id) == ["a", "b", "c"])
        #expect(model.groups.count == 2)
        model.moveSelection(1)
        #expect(model.selection == "a")
        model.moveSelection(5)
        #expect(model.selection == "c")
        model.moveSelection(-1)
        #expect(model.selection == "b")
        model.grouping = .machine
        #expect(model.groups.count == 1)
    }

    @Test func addressMatchesOnlyTheHistoryPage() {
        #expect(HistoryPageAddress.matches(URL(string: "cmux://history")))
        #expect(HistoryPageAddress.matches(URL(string: "CMUX://History/")))
        #expect(!HistoryPageAddress.matches(URL(string: "cmux://settings")))
        #expect(!HistoryPageAddress.matches(URL(string: "https://history")))
    }
}
