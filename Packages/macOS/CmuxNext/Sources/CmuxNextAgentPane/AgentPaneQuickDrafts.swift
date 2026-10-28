/// A fresh Quick Composer has no tab or session yet. Its controller keeps the
/// text and chips in the app's stable draft stores under this fixed identity.
@MainActor
public final class AgentPaneQuickDrafts {
    public static let sessionID = "quick-composer-v1"
    /// Owns and orders the callbacks' writes until the quit boundary awaits them.
    private var pending: Task<Void, Never>?

    public init() {}

    public func set(_ text: String, attachments: [AgentPaneWakeState.Attachment]) {
        enqueue { store in
            try? await store.draftTexts.set(text, for: Self.sessionID)
            _ = await store.keep(AgentPaneDraftAttachments.json(attachments), for: Self.sessionID)
        }
    }

    public func clear() {
        enqueue { store in
            try? await store.draftTexts.set("", for: Self.sessionID)
            _ = await store.keep(AgentPaneDraftAttachments.json([]), for: Self.sessionID)
        }
    }

    /// The first ready awaits this source before the page can send a prompt.
    public func wakeState() async -> AgentPaneWakeState? {
        await pending?.value
        guard let store = AgentPaneDraftAttachments.shared else { return nil }
        let text = try? await store.draftTexts.get(Self.sessionID)
        let attachments = await store.attachments(for: Self.sessionID)
        guard text != nil || !attachments.isEmpty else { return nil }
        return AgentPaneWakeState(attachments: attachments, draftText: text)
    }

    /// A page that cannot answer leaves the last durable value intact. A live
    /// page supplies the latest keystrokes and chips, even before their debounce.
    public func saveWakeState(_ state: AgentPaneWakeState?) async {
        if let state {
            enqueue { store in
                if let text = state.draftText { try? await store.draftTexts.set(text, for: Self.sessionID) }
                if let attachments = state.attachments {
                    _ = await store.keep(AgentPaneDraftAttachments.json(attachments), for: Self.sessionID)
                }
            }
        }
        await pending?.value
    }

    private func enqueue(_ write: @escaping @MainActor (AgentPaneDraftAttachments) async -> Void) {
        let previous = pending
        pending = Task {
            await previous?.value
            guard let store = AgentPaneDraftAttachments.shared else { return }
            await write(store)
        }
    }
}
