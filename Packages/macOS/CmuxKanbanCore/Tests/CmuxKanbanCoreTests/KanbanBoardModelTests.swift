import Foundation
import Testing

@testable import CmuxKanbanCore

@Suite
struct KanbanBoardModelTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static let later = Date(timeIntervalSince1970: 1_700_000_100)

    @Test
    func upsertingInsertsThenReplacesById() {
        let id = UUID()
        var board = KanbanBoard.empty(workspaceId: UUID(), now: Self.now)
        board = board.upserting(
            KanbanCard(id: id, title: "First", createdAt: Self.now, updatedAt: Self.now),
            now: Self.now
        )
        #expect(board.cards.count == 1)

        board = board.upserting(
            KanbanCard(id: id, title: "Renamed", createdAt: Self.now, updatedAt: Self.now),
            now: Self.later
        )
        #expect(board.cards.count == 1)
        #expect(board.cards[0].title == "Renamed")
        #expect(board.cards[0].updatedAt == Self.later)
    }

    @Test
    func movingCardUpdatesColumnAndWipCount() {
        let id = UUID()
        var board = KanbanBoard.empty(workspaceId: UUID(), now: Self.now)
        board = board.upserting(
            KanbanCard(id: id, title: "Task", column: .ready, createdAt: Self.now, updatedAt: Self.now),
            now: Self.now
        )
        #expect(board.wipInUse == 0)

        board = board.movingCard(id: id, to: .building, now: Self.later)
        #expect(board.cards(in: .building).count == 1)
        #expect(board.wipInUse == 1)
    }

    @Test
    func reconcileRequeuesInFlightCardsWhenRipping() {
        let buildingId = UUID()
        let testingId = UUID()
        var board = KanbanBoard(workspaceId: UUID(), ripping: true, updatedAt: Self.now)
        board = board.upserting(
            KanbanCard(id: buildingId, title: "A", column: .building, sessionId: "s1", createdAt: Self.now, updatedAt: Self.now),
            now: Self.now
        )
        board = board.upserting(
            KanbanCard(id: testingId, title: "B", column: .testing, sessionId: "s2", createdAt: Self.now, updatedAt: Self.now),
            now: Self.now
        )

        let reconciled = board.reconcilingOrphansAfterRelaunch(now: Self.later)
        #expect(reconciled.cards(in: .ready).count == 2)
        #expect(reconciled.cards.allSatisfy { $0.sessionId == nil })
    }

    @Test
    func reconcileFailsInFlightCardsWhenNotRipping() {
        let id = UUID()
        var board = KanbanBoard(workspaceId: UUID(), ripping: false, updatedAt: Self.now)
        board = board.upserting(
            KanbanCard(id: id, title: "A", column: .building, sessionId: "s1", createdAt: Self.now, updatedAt: Self.now),
            now: Self.now
        )

        let reconciled = board.reconcilingOrphansAfterRelaunch(now: Self.later)
        #expect(reconciled.cards(in: .failed).count == 1)
        #expect(reconciled.cards(in: .ready).isEmpty)
    }

    @Test
    func unknownColumnDecodesToBacklog() throws {
        let json = Data(#"{"column":"warp-core-breach"}"#.utf8)
        struct Holder: Codable { let column: KanbanColumn }
        let holder = try JSONDecoder().decode(Holder.self, from: json)
        #expect(holder.column == .backlog)
    }
}
