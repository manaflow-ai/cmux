public import CmuxNextWakeups
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
    /// Writes the places off the main thread; nil keeps nothing on disk.
    private let writer: StateFileWriter?
    /// Oldest first; read from the file on first use.
    private var entries: [Entry]?

    /// - Parameters:
    ///   - directory: The tag's state directory; nil keeps nothing.
    ///   - work: The app's blocking-work lanes, where each save is encoded and written.
    ///   - write: Puts a save on disk, on a lane thread; default the disk (tests record where it runs).
    public init(directory: URL?, work: BackgroundWork, write: @escaping StateFileWriter.Write = StateFileWriter.disk) {
        file = directory?.appending(path: Self.fileName)
        writer = file.map { StateFileWriter(file: $0, work: work, write: write) }
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
        // concurrency-allow: one read of a small local state file, at the first chat's attach
        let data = file.flatMap { try? Data(contentsOf: $0) }
        let read = data.flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        entries = read
        return read
    }

    /// Returns once every save so far is on disk (tests; the quit awaits the lanes instead).
    public func flushed() async {
        await writer?.flushed()
    }

    /// Hands the places to the writer: encoded and written on the files lane, never on the main thread;
    /// none left removes the file.
    private func save() {
        guard let entries else { return }
        writer?.save { entries.isEmpty ? nil : try JSONEncoder().encode(entries) }
    }
}
