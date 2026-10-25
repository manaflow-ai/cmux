import CmuxNextWakeups
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

    nonisolated private struct Entry: Codable, Equatable, Sendable {
        var sessionId: String
        var anchor: AgentPaneScrollAnchor
    }

    let file: URL?
    /// Writes the file off the main actor, newest state last.
    private let store: AgentPaneStateFile<[Entry]>?
    /// The number of the newest state handed to ``store``.
    private var saved: UInt64 = 0
    /// Oldest first; read from the file on first use.
    private var entries: [Entry]?

    public convenience init(directory: URL?) {
        self.init(directory: directory, writer: AgentPaneStateFileDiskWriter())
    }

    /// - Parameter writer: where the file's bytes go (tests record them).
    init(directory: URL?, writer: any AgentPaneStateFileWriting) {
        file = directory?.appending(path: Self.fileName)
        store = file.map { AgentPaneStateFile<[Entry]>(url: $0, writer: writer) }
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

    /// Returns when the newest place kept is on disk (quit awaits it).
    public func flush() async {
        guard let store, saved > 0 else { return }
        await store.write(state, sequence: saved)
    }

    /// Hands the places to ``store``, numbered, to be written off the main actor.
    private func save() {
        guard let store else { return }
        saved += 1
        let state = self.state, sequence = saved
        Task(priority: WorkPriority.bestEffort.taskPriority) { await store.write(state, sequence: sequence) }
    }

    /// What the file holds: nil (no file) when no chat has a place.
    private var state: [Entry]? {
        entries.flatMap { $0.isEmpty ? nil : $0 }
    }
}
