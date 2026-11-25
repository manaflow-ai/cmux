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

        // Offline with Mac A's rows kept on screen, the phone moves to Mac B: they go.
        session.use(ChiefOfflineBackend())
        #expect(session.store.isShowingKeptTranscript)
        session.macID = "mac-B"
        #expect(session.store.messages.isEmpty)
        #expect(!session.store.isShowingKeptTranscript)

        // Sign-out: the kept rows on screen go, and nothing comes back for the next account.
        session.macID = "mac-A"
        #expect(session.store.isShowingKeptTranscript)
        session.discardTranscripts()
        #expect(session.store.messages.isEmpty)
        session.use(ChiefOfflineBackend())
        #expect(session.store.messages.isEmpty)
    }

    /// A Chief made on its backend (a relaunch: the session is built with the Chief's backend,
    /// not swapped to it) shows the kept messages at once. Before, a session that did not name
    /// a fixed transcript key kept none in its init, and the relaunch showed the spinner.
    @Test func aChiefMadeOnItsBackendShowsTheKeptMessagesAtOnce() async throws {
        let cache = ConversationTranscriptCache(directory: FileManager.default.temporaryDirectory
            .appending(path: "chief-transcripts-\(UUID().uuidString)"))
        defer { cache.removeAll() }
        let outbox = ChiefOutbox(file: FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString).json"))
        let first = ChiefSession(backend: ChiefMockBackend(sleep: { _ in }), outbox: outbox, transcripts: cache)
        try await waitUntil("the mock Chief to load") { first.store.hasLoadedNewest && !first.store.messages.isEmpty }
        let seen = first.store.messages.compactMap(\.seq)

        let relaunched = ChiefSession(backend: ChiefMockBackend(sleep: { _ in }), outbox: outbox, transcripts: cache)
        #expect(relaunched.store.messages.compactMap(\.seq) == seen)
        #expect(relaunched.store.isShowingKeptTranscript)
    }

    /// Messages that came while the app was away are not alerted as new when the page brings
    /// them after the kept rows: before, the kept seq became the "seen" mark.
    @Test func keptRowsAreNotTheSeenMark() async throws {
        let cache = ConversationTranscriptCache(directory: FileManager.default.temporaryDirectory
            .appending(path: "chief-transcripts-\(UUID().uuidString)"))
        defer { cache.removeAll() }
        let outbox = ChiefOutbox(file: FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString).json"))
        let session = ChiefSession(backend: ChiefOfflineBackend(), outbox: outbox, transcripts: cache)
        session.macID = "mac-A"
        session.use(ChiefMockBackend(sleep: { _ in }))
        try await waitUntil("Mac A's Chief to load") { session.store.hasLoadedNewest && !session.store.messages.isEmpty }
        // Kept rows end before Chief's newest message: the page brings it, as history.
        let chiefs = try #require(session.store.messages.last { $0.seq != nil && $0.senderID == session.identity.chiefID }?.seq)
        cache.save("mac:mac-A", info: session.store.info, meID: session.store.meID,
                   messages: session.store.messages.filter { ($0.seq ?? 0) < chiefs })
        var alerted: [String] = []
        session.onAlert = { alerted.append($0.id) }
        session.use(ChiefMockBackend(sleep: { _ in }))
        #expect(session.store.isShowingKeptTranscript)
        try await waitUntil("the page") { session.store.hasLoadedNewest }
        #expect(alerted.isEmpty)
    }
}
