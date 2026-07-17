import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct OfflineAgentNoteQueueTests {
    private static let workspaceID = MobileWorkspacePreview.ID(rawValue: "ws-offline")
    private static let terminalID = MobileTerminalPreview.ID(rawValue: "term-offline")

    @Test func fileStorePersistsNotesAndNormalizesInterruptedSending() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-offline-notes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("notes.json", isDirectory: false)
        let store = FileOfflineAgentNoteQueueStore(fileURL: fileURL)
        let now = Date()
        let note = OfflineAgentNote(
            text: "follow up when online",
            workspaceID: "ws",
            terminalID: "term",
            createdAt: now,
            updatedAt: now,
            status: .sending
        )

        await store.saveNotes([note])
        let reloaded = await FileOfflineAgentNoteQueueStore(fileURL: fileURL).loadNotes()

        #expect(reloaded.count == 1)
        #expect(reloaded.first?.text == "follow up when online")
        #expect(reloaded.first?.status == .pending)
    }

    @Test func composerSendWithoutMacQueuesTextAndClearsDraft() async throws {
        let queue = RecordingOfflineAgentNoteQueue()
        let store = Self.makeOfflineStore(queue: queue)
        store.terminalInputText = "ask an agent to check the build"

        await store.submitComposer()

        #expect(store.terminalInputText == "")
        #expect(store.offlineAgentNotes.count == 1)
        #expect(store.offlineAgentNotes.first?.status == .pending)
        #expect(store.offlineAgentNotes.first?.text == "ask an agent to check the build")
        let persisted = await Self.waitForSavedNotes(in: queue, count: 1)
        #expect(persisted.first?.status == .pending)
    }

    @Test func queuedNoteReplaysThroughTerminalPasteWhenRetriedOnline() async throws {
        let now = Date()
        let queued = OfflineAgentNote(
            text: "run the queued task",
            workspaceID: RoutingHostRouter.workspaceID,
            terminalID: RoutingHostRouter.terminalA,
            createdAt: now,
            updatedAt: now,
            status: .pending
        )
        let queue = RecordingOfflineAgentNoteQueue(initial: [queued])
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(router: router, offlineAgentNoteQueue: queue)

        await Self.waitUntil {
            store.offlineAgentNotes.contains { $0.id == queued.id }
        }
        await store.retryOfflineAgentNotes()

        let pastes = await router.recordedPastes()
        #expect(pastes.map(\.surfaceID) == [RoutingHostRouter.terminalA])
        #expect(pastes.map(\.text) == ["run the queued task"])
        #expect(store.offlineAgentNotes.first(where: { $0.id == queued.id })?.status == .sent)
        let persisted = await Self.waitForSavedNotes(in: queue, count: 1)
        #expect(persisted.first?.status == .sent)
    }

    private static func makeOfflineStore(queue: RecordingOfflineAgentNoteQueue) -> MobileShellComposite {
        MobileShellComposite(
            isSignedIn: true,
            workspaces: [
                MobileWorkspacePreview(
                    id: workspaceID,
                    name: "Offline Workspace",
                    terminals: [
                        MobileTerminalPreview(id: terminalID, name: "Agent"),
                    ]
                ),
            ],
            offlineAgentNoteQueue: queue
        )
    }

    private static func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async {
        for _ in 0..<100 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private static func waitForSavedNotes(
        in queue: RecordingOfflineAgentNoteQueue,
        count: Int
    ) async -> [OfflineAgentNote] {
        for _ in 0..<100 {
            let notes = await queue.savedNotes()
            if notes.count == count {
                return notes
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await queue.savedNotes()
    }
}

private actor RecordingOfflineAgentNoteQueue: OfflineAgentNoteQueueStoring {
    private var notes: [OfflineAgentNote]

    init(initial: [OfflineAgentNote] = []) {
        self.notes = initial
    }

    func loadNotes() async -> [OfflineAgentNote] {
        notes
    }

    func saveNotes(_ notes: [OfflineAgentNote]) async {
        self.notes = notes
    }

    func savedNotes() -> [OfflineAgentNote] {
        notes
    }
}
