import Foundation
import Testing

@testable import CmuxKanbanCore

@Suite(.serialized)
struct KanbanBoardRepositoryTests {
    /// A fixed instant (no sub-second component) so `.iso8601` round-trips exactly.
    private static let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeTempBaseDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("KanbanBoardRepositoryTests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test
    func loadReturnsEmptyBoardWhenFileMissing() async throws {
        let base = makeTempBaseDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = KanbanBoardRepository(baseDirectory: base)
        let workspaceId = UUID()

        let board = try await repo.load(workspaceId: workspaceId, now: Self.fixedNow)

        #expect(board.workspaceId == workspaceId)
        #expect(board.cards.isEmpty)
        #expect(board.wipLimit == 2)
        #expect(board.ripping == false)
        #expect(board.schemaVersion == KanbanBoard.currentSchemaVersion)
    }

    @Test
    func saveThenLoadRoundTripsBoardWithCards() async throws {
        let base = makeTempBaseDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = KanbanBoardRepository(baseDirectory: base)
        let workspaceId = UUID()

        let card = KanbanCard(
            title: "Fix the login bug",
            detail: "Reproduce, root-cause, patch, add regression test.",
            column: .ready,
            backendKind: .cmux,
            agentProvider: "claude",
            createdAt: Self.fixedNow,
            updatedAt: Self.fixedNow
        )
        let board = KanbanBoard(
            workspaceId: workspaceId,
            wipLimit: 3,
            ripping: true,
            testCommand: "bun test",
            cards: [card],
            updatedAt: Self.fixedNow
        )

        try await repo.save(board)
        let loaded = try await repo.load(workspaceId: workspaceId, now: Self.fixedNow)

        #expect(loaded == board)
        #expect(loaded.cards.count == 1)
        #expect(loaded.cards[0].title == "Fix the login bug")
        #expect(loaded.cards[0].agentProvider == "claude")
        #expect(loaded.testCommand == "bun test")
    }

    @Test
    func loadThrowsOnCorruptedBoardFile() async throws {
        let base = makeTempBaseDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = KanbanBoardRepository(baseDirectory: base)
        let workspaceId = UUID()

        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try Data("{ not valid json ".utf8).write(to: await repo.boardURL(workspaceId: workspaceId))

        await #expect(throws: KanbanBoardRepositoryError.corruptedBoardFile(workspaceId: workspaceId)) {
            _ = try await repo.load(workspaceId: workspaceId, now: Self.fixedNow)
        }
    }

    @Test
    func appendLogAccumulatesAcrossCalls() async throws {
        let base = makeTempBaseDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = KanbanBoardRepository(baseDirectory: base)
        let cardId = UUID()

        try await repo.appendLog(cardId: cardId, text: "line one\n")
        try await repo.appendLog(cardId: cardId, text: "line two\n")

        let contents = try String(contentsOf: await repo.logURL(cardId: cardId), encoding: .utf8)
        #expect(contents == "line one\nline two\n")
    }
}
