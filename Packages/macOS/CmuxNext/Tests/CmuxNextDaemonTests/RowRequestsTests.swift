import Foundation
import Testing
@testable import CmuxNextDaemon

/// `new-row` and `set-row-heights` (`rows-v1`, cmux-tui/spec/commands.md)
/// on the wire, and the row-height intent shown over the mirror until the
/// daemon settles or refuses it (OWNERSHIP-PRINCIPLES.md).
@Suite struct RowRequestsTests {
    private func object<R: DaemonRequest>(_ request: R) throws -> [String: JSONValue] {
        let data = try WireCoding.encodeRequest(request, id: 7)
        guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw DaemonError.malformedResponse("not an object")
        }
        return object
    }

    @Test func newRowCarriesThePaneHeightAndSpawnOptions() throws {
        let json = try object(NewRowRequest(pane: 15, height: 500, options: SpawnOptions(cwd: "/tmp")))
        #expect(json["cmd"] == .string("new-row"))
        #expect(json["pane"] == .number(15))
        #expect(json["height_permille"] == .number(500))
        #expect(json["cwd"] == .string("/tmp"))
    }

    @Test func setRowHeightsNamesEveryRow() throws {
        let json = try object(SetRowHeightsRequest(column: 14, heights: [RowHeightValue(row: 40, height: 600),
                                                                       RowHeightValue(row: 41, height: 400)], fit: true))
        #expect(json["cmd"] == .string("set-row-heights"))
        #expect(json["column"] == .number(14))
        #expect(json["fit"] == .bool(true))
        #expect(json["heights"] == .array([.object(["row": .number(40), "height": .number(600)]),
                                            .object(["row": .number(41), "height": .number(400)])]))
        #expect(json["transaction"] == nil)
    }
}

@MainActor @Suite struct RowHeightIntentTests {
    /// The fixture's column 9 (pane 4 over pane 11) as two rows.
    private func loaded() throws -> DaemonStore {
        var tree = try Fixture.response(DaemonTree.self, "list-workspaces.json")
        tree.workspaces[0].screens[0].columns[0].rows = [RowSnapshot(id: 30, height: 600, layout: .leaf(4)),
                                                         RowSnapshot(id: 12, height: 400, layout: .leaf(11))]
        let store = DaemonStore()
        store.apply(snapshot: tree)
        return store
    }

    private func heights(_ store: DaemonStore) -> [Int] {
        store.screen(5)?.columns.first { $0.id == 9 }?.rows.map(\.height) ?? []
    }

    @Test func theIntentShowsAtOnceAndARejectionRestoresTheMirror() throws {
        let store = try loaded()
        #expect(heights(store) == [600, 400])
        store.intend(.setRowHeights(column: 9, heights: [RowHeightValue(row: 30, height: 700), RowHeightValue(row: 12, height: 300)]),
                     transaction: "rows")
        #expect(heights(store) == [700, 300])
        store.rejectIntent("rows")
        #expect(heights(store) == [600, 400])
        #expect(!store.hasPendingIntents)
    }

    @Test func aStaleRowSetChangesNothing() throws {
        let store = try loaded()
        store.intend(.setRowHeights(column: 9, heights: [RowHeightValue(row: 30, height: 700)]), transaction: "stale")
        #expect(heights(store) == [600, 400])
        store.intend(.setRowHeights(column: 99, heights: [RowHeightValue(row: 30, height: 700)]), transaction: "gone")
        #expect(heights(store) == [600, 400])
    }
}
