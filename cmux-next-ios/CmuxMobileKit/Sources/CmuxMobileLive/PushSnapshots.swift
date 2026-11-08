import CmuxConversationCore
import CmuxMobileAgentChat
import CmuxMobileChief
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

    /// Chief's conversation: the person's messages and Chief's, unsent and
    /// scheduled ones and status rows left out, a message with only
    /// attachments named by them.
    public static func chiefMessages(_ messages: [ConversationMessage], chiefID: String) -> [PushSnapshot.Message] {
        var out: [PushSnapshot.Message] = []
        for message in messages where !message.isUnsent && !message.isScheduled && message.systemEvent == nil {
            let text = message.text.isEmpty ? attachmentLabel(message.attachments) : message.text
            guard let text, !text.isEmpty else { continue }
            out.append(.init(role: message.senderID == chiefID ? .agent : .user, text: text))
        }
        return Array(out.suffix(PushSnapshotStore.maxMessages))
    }

    static func attachmentLabel(_ attachments: [ConversationAttachment]) -> String? {
        guard let first = attachments.first else { return nil }
        let count = attachments.count
        return switch first.kind {
        case .image: count == 1 ? String(localized: "Photo") : String(localized: "\(count) Photos")
        case .audio: String(localized: "Audio Message")
        case .file: count == 1 ? String(localized: "Attachment") : String(localized: "\(count) Attachments")
        }
    }

    /// The Mac Chief's conversation, under that Mac (`PushSnapshot.chiefSession`),
    /// with the name and avatar the Mac set: the long look of a Chief push draws them.
    static func chief(_ session: ChiefSession) -> PushSnapshot? {
        guard let mac = session.macID, !mac.isEmpty else { return nil }
        let messages = chiefMessages(session.store.messages, chiefID: session.identity.chiefID)
        guard !messages.isEmpty else { return nil }
        return PushSnapshot(mac: mac, session: PushSnapshot.chiefSession, title: session.title ?? session.identity.title,
                            avatar: session.avatar, messages: messages)
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
        if let chief = Self.chief(.shared) { snapshots.append(chief) }
        guard !snapshots.isEmpty else { return }
        let toSave = snapshots
        // Writes and the sign-out wipe run one after another; a save that read its chats before a
        // sign-out writes nothing (it would put the signed-out account's chats back).
        let epoch = Self.epoch
        let previous = Self.writes
        let write = Task.detached(priority: .utility) {
            await previous?.value
            guard await MainActor.run(body: { Self.epoch == epoch }) else { return }
            for snapshot in toSave { store.save(snapshot) }
        }
        Self.writes = write
        await write.value
    }
    #endif

    /// Counts sign-outs: a save that began before one must not write after it (`save`).
    private static var epoch = 0
    /// The newest disk job (a save's write or a wipe); the next one waits for it.
    private static var writes: Task<Void, Never>?

    /// Sign-out: no account's chats stay on disk, whatever save was already writing or about to
    /// write (off the main thread). Await the result before work that must follow the wipe.
    public static func clearForSignOut() -> Task<Void, Never> {
        epoch += 1
        let previous = writes
        let clear = Task.detached(priority: .utility) {
            await previous?.value
            let group = await PushAppGroup.resolved(timeout: PushAppGroupResolver.cleanupTimeout)
            PushSnapshotStore(group: group)?.removeAll()
        }
        writes = clear
        return clear
    }

    /// Sign-out: no account's chats stay on disk (off the main thread).
    public func removeAll() async {
        let group = await PushAppGroup.resolved(timeout: PushAppGroupResolver.cleanupTimeout)
        await Task.detached(priority: .utility) { PushSnapshotStore(group: group)?.removeAll() }.value
    }
}
