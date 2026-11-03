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

/// Where each agent chat rested, by session, in a JSON file beside the launch snapshot, so a
/// relaunch or a crash reopens a chat where the reader left it instead of at its latest message.
/// The page reads its chat's place before it attaches (`chat.scrollAnchor.get`) and writes it once
/// a scroll settles (`chat.scrollAnchor`); the most recent ``limit`` chats are kept.
@MainActor
public final class AgentPaneScrollAnchors {
    public static let fileName = "agent-scroll-anchors.json"
    /// The app's store; nil keeps no places (a test host, the gallery).
    public static var shared: AgentPaneScrollAnchors?
    static let limit = 500

    private nonisolated struct Entry: Codable, Equatable, Sendable {
        var sessionId: String
        var anchor: AgentPaneScrollAnchor
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

    public func anchor(for sessionId: String) -> AgentPaneScrollAnchor? {
        loaded().last { $0.sessionId == sessionId }?.anchor
    }

    /// Keeps chat `sessionId`'s place; nil (at the latest message) forgets it.
    public func remember(_ anchor: AgentPaneScrollAnchor?, for sessionId: String) {
        var kept = loaded().filter { $0.sessionId != sessionId }
        if let anchor { kept.append(Entry(sessionId: sessionId, anchor: anchor)) }
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
