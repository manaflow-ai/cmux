public import Foundation

/// Where a chat's transcript rests (cx-6bgzj): the row at the top of the view and how far into it.
/// A chat at its latest message has none: it reopens following the reply anyway.
public nonisolated struct AgentPaneScrollAnchor: Codable, Sendable, Equatable {
    public var rowId: String
    public var offset: Double

    public init(rowId: String, offset: Double) {
        self.rowId = rowId
        self.offset = offset
    }
}

/// Where each agent chat rested, by session and tab, in a JSON file beside the launch snapshot, so a
/// relaunch or a crash reopens a chat where the reader left it instead of at its latest message.
/// The page reads its chat's place before it attaches (`chat.scrollAnchor.get`) and writes it once
/// a scroll settles (`chat.scrollAnchor`); the most recent ``limit`` places are kept.
///
/// One chat can be open in two tabs at once (Leo, 2026-11-03: "right split is fine on click by
/// default (extra view doesn't really affect anything)"), so a place is kept per tab: a tab's reload
/// reopens where that tab rested, never where the other one did. A tab with no place of its own (a
/// tab opened on the chat later, or one saved before places were per tab) takes the chat's most
/// recent place, whichever tab left it.
@MainActor
public final class AgentPaneScrollAnchors {
    public static let fileName = "agent-scroll-anchors.json"
    /// The app's store; nil keeps no places (a test host, the gallery).
    public static var shared: AgentPaneScrollAnchors?
    static let limit = 500

    private nonisolated struct Entry: Codable, Equatable, Sendable {
        var sessionId: String
        /// The tab that rested here; nil for a place saved before places were per tab, or by a
        /// page that is no tab's (it stays the chat's place for a tab with none of its own).
        var tab: String?
        /// Nil: the tab rested at the chat's latest message. Kept, so that tab's reload does not
        /// take the other tab's place instead.
        var anchor: AgentPaneScrollAnchor?
    }

    let file: URL?
    /// Saves leave the main thread: every settled scroll of a chat saves.
    private let store: AgentPaneStateFile?
    /// Oldest first; read from the file on first use.
    private var entries: [Entry]?

    /// - Parameter files: The app's state files (`AppServices`), so the file has one writer.
    public init(directory: URL?, files: AgentPaneStateFiles) {
        file = directory?.appending(path: Self.fileName)
        store = file.map(files.at)
    }

    /// Where chat `sessionId` rests in tab `tab`: that tab's own place, else the chat's most recent
    /// one in any tab (an entry from before places were per tab included).
    public func anchor(for sessionId: String, tab: String? = nil) -> AgentPaneScrollAnchor? {
        let entries = loaded()
        if let tab, let own = entries.last(where: { $0.sessionId == sessionId && $0.tab == tab }) { return own.anchor }
        return entries.last { $0.sessionId == sessionId }?.anchor
    }

    /// Keeps chat `sessionId`'s place in tab `tab`; nil is its latest message. No tab (a page that
    /// is no tab's): nil forgets the chat's tabless place.
    public func remember(_ anchor: AgentPaneScrollAnchor?, for sessionId: String, tab: String? = nil) {
        var kept = loaded().filter { $0.sessionId != sessionId || $0.tab != tab }
        if tab != nil || anchor != nil { kept.append(Entry(sessionId: sessionId, tab: tab, anchor: anchor)) }
        kept = Array(kept.suffix(Self.limit))
        guard kept != entries else { return }
        entries = kept
        save()
    }

    private func loaded() -> [Entry] {
        if let entries { return entries }
        let data = store?.read()
        let read = data.flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        entries = read
        return read
    }

    private func save() {
        guard let store, let entries else { return }
        store.write { entries.isEmpty ? nil : try JSONEncoder().encode(entries) }
    }
}
