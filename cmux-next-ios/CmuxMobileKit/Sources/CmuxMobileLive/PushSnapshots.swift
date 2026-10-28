import CmuxMobileAgentChat
import CmuxMobileNotifications
import Foundation

/// The last messages of the chats loaded in this launch, saved for the
/// notification content extension's preview (it has no link). Cheap: only
/// when the app goes to the background, only chats already in memory, and
/// the store skips a file whose messages did not change.
@MainActor
public struct PushSnapshots {
    public init() {}

    /// The last messages of `turns`: each prompt, then the agent's replies.
    public static func messages(_ turns: [AgentTurn]) -> [PushSnapshot.Message] {
        var out: [PushSnapshot.Message] = []
        for turn in turns.suffix(PushSnapshotStore.maxMessages) {
            if !turn.prompt.isEmpty { out.append(.init(role: .user, text: turn.prompt)) }
            for case .message(_, let markdown) in turn.items where !markdown.isEmpty {
                out.append(.init(role: .agent, text: markdown))
            }
            if turn.status == .failed, let error = turn.errorText { out.append(.init(role: .system, text: error)) }
        }
        return Array(out.suffix(PushSnapshotStore.maxMessages))
    }

    #if os(iOS)
    // AgentSessionDirectory is iOS only; the package's macOS `swift test` builds this file too.
    /// The App Group resolves and the files are written off the main thread;
    /// a build without the group saves nothing (the long look shows the push alone).
    public func save(directory: AgentSessionDirectory = .shared) async {
        guard let store = PushSnapshotStore(group: await PushAppGroup.resolved()) else { return }
        var snapshots: [PushSnapshot] = []
        for chat in directory.loadedStores {
            guard let source = chat.source as? AcpmuxSessionSource, !chat.summary.macID.isEmpty else { continue }
            let messages = Self.messages(chat.turns)
            guard !messages.isEmpty else { continue }
            snapshots.append(PushSnapshot(mac: chat.summary.macID, session: source.sessionID, title: chat.summary.name, messages: messages))
        }
        guard !snapshots.isEmpty else { return }
        let toSave = snapshots
        await Task.detached(priority: .utility) { for snapshot in toSave { store.save(snapshot) } }.value
    }
    #endif

    /// Sign-out: no account's chats stay on disk (off the main thread).
    public func removeAll() async {
        let group = await PushAppGroup.resolved(timeout: PushAppGroupResolver.cleanupTimeout)
        await Task.detached(priority: .utility) { PushSnapshotStore(group: group)?.removeAll() }.value
    }
}
