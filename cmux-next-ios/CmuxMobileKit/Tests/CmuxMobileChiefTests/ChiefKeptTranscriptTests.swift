import CmuxConversationCore
import Foundation
import Testing
@testable import CmuxMobileChief

/// The user, 2026-11-06: Chief keeps its newest messages on the phone, "so I don't just see a
/// loading spinner when I come back from app background", like Messages and WhatsApp. Coming
/// back swaps the backend (offline, then the Mac's Chief), and each swap built an empty store
/// that showed the spinner until the newest page arrived. Now each new store shows the kept
/// messages in the same turn.
@Suite @MainActor struct ChiefKeptTranscriptTests {
    @Test func comingBackShowsTheKeptMessagesAtOnce() async throws {
        let cache = ConversationTranscriptCache(directory: FileManager.default.temporaryDirectory
            .appending(path: "chief-transcripts-\(UUID().uuidString)"))
        defer { cache.removeAll() }
        let outbox = ChiefOutbox(file: FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString).json"))
        let session = ChiefSession(backend: ChiefOfflineBackend(), outbox: outbox, transcripts: cache)
        session.macID = "mac-A"
        session.use(ChiefMockBackend(sleep: { _ in }))
        try await waitUntil("Mac A's Chief to load") { session.store.hasLoadedNewest && !session.store.messages.isEmpty }
        let seen = session.store.messages.compactMap(\.seq)

        // The app leaves the foreground: the link drops, an offline store replaces the live one.
        session.use(ChiefOfflineBackend())
        #expect(session.store.messages.compactMap(\.seq) == seen)
        #expect(session.store.isShowingKeptTranscript)

        // Back in the foreground: the Mac's Chief again, its rows before its first page.
        session.use(ChiefMockBackend(sleep: { _ in }))
        #expect(session.store.messages.compactMap(\.seq) == seen)
        #expect(session.store.isShowingKeptTranscript)
        try await waitUntil("the newest page to replace them") { session.store.hasLoadedNewest }
        #expect(!session.store.isShowingKeptTranscript)

        // Another Mac's Chief never shows Mac A's messages.
        session.macID = "mac-B"
        session.use(ChiefOfflineBackend())
        #expect(session.store.messages.isEmpty)
        #expect(!session.store.isShowingKeptTranscript)
    }
}
