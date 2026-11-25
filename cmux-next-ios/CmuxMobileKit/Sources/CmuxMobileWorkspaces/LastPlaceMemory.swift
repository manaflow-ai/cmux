import CmuxMobileAgentChat
import Foundation
#if canImport(CmuxMobileLinkFFI)
import CmuxMobileLinkFFI
#endif

/// Where the person was (the workspace, its chat or terminal, the scroll anchor, the selection),
/// kept across launches so the app opens there. Every rule (what is kept, when it is stale, the
/// debounce of writes, a corrupt file) is Rust's `cmux-mobile-last-place`, behind
/// `LastPlaceStore`; this only passes moves and scroll rests in, schedules the write Rust asks
/// for, and reads the anchor back. The file is read once, synchronously, when `shared` is
/// first used, and never waits on the network. Without the Rust library (the macOS test build)
/// it keeps nothing.
@MainActor
public final class LastPlaceMemory {
    /// The app's: Application Support/cmux-mobile-live/last-place.json.
    public static let shared = LastPlaceMemory(fileURL: defaultURL)

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("cmux-mobile-live", isDirectory: true).appendingPathComponent("last-place.json")
    }

    #if canImport(CmuxMobileLinkFFI)
    private let store: LastPlaceStore
    #endif
    private var tickTask: Task<Void, Never>?
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant

    public init(fileURL: URL) {
        origin = clock.now
        #if canImport(CmuxMobileLinkFFI)
        store = LastPlaceStore.open(path: fileURL.path)
        #endif
    }

    private var nowMs: UInt64 {
        let elapsed = clock.now - origin
        return UInt64(max(0, elapsed.components.seconds)) * 1000 + UInt64(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    /// The person is on `tabID` of `workspaceID` (nil: the list), as a chat or a terminal.
    public func noteLocation(workspaceID: String?, tabID: String?, isChat: Bool) {
        #if canImport(CmuxMobileLinkFFI)
        schedule(store.noteLocation(workspaceId: workspaceID, screen: workspaceID == nil ? nil : (isChat ? .chat : .terminal),
                                    itemId: tabID, nowMs: nowMs))
        #endif
    }

    #if os(iOS)  // ChatReadingAnchor is iOS-only (AgentChatScreen.swift)
    /// The reader of `tabID` came to rest at `anchor` (nil: on the newest turn).
    public func noteReading(workspaceID: String, tabID: String, anchor: ChatReadingAnchor?) {
        #if canImport(CmuxMobileLinkFFI)
        schedule(store.noteScroll(workspaceId: workspaceID, itemId: tabID,
                                  anchor: anchor.map { LastPlaceAnchor(row: $0.row, offset: $0.offset) }, nowMs: nowMs))
        #endif
    }

    /// Where `tabID` of `workspaceID` was read, when it is the kept place.
    public func readingAnchor(workspaceID: String, tabID: String) -> ChatReadingAnchor? {
        #if canImport(CmuxMobileLinkFFI)
        return store.scrollFor(workspaceId: workspaceID, itemId: tabID).map { ChatReadingAnchor(row: $0.row, offset: $0.offset) }
        #else
        return nil
        #endif
    }
    #endif

    /// The app goes to the background: write what waits now.
    public func flush() {
        tickTask?.cancel()
        tickTask = nil
        #if canImport(CmuxMobileLinkFFI)
        _ = store.flush()
        #endif
    }

    /// Rust asked to be ticked at `dueMs`: one timer, the latest deadline.
    private func schedule(_ dueMs: UInt64?) {
        tickTask?.cancel()
        tickTask = nil
        #if canImport(CmuxMobileLinkFFI)
        guard let dueMs else { return }
        let wait = dueMs > nowMs ? dueMs - nowMs : 0
        tickTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(wait))
            guard !Task.isCancelled, let self else { return }
            self.schedule(self.store.tick(nowMs: self.nowMs))
        }
        #endif
    }
}
