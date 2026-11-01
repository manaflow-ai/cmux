public import Foundation
import CmuxNextSettings

/// Read aloud in agent chats (the speaker under a message): one voice for the whole app, so a
/// second press, Escape, closing the chat, and Stop Reading Aloud (palette, CLI, MCP) all stop it.
///
/// The page used to speak through its own web view's speech synthesis; once that view closed or
/// hibernated mid-message nothing could reach the voice and it read on (user, 2026-10-29). Now the
/// page asks (`readAloud.speak`, `readAloud.stop`) and draws what the `readAloud` event says.
/// App-wide: the App makes one (its agent tab store) and hands it to every chat's model
/// (``AgentPaneModel/readAloud``), so a chat's page and the palette's Stop reach the same voice; a
/// test makes its own with a fake voice.
@MainActor
public final class AgentPaneReadAloud {
    /// A reader on the system voice.
    public convenience init() {
        self.init(voice: AgentPaneSystemVoice())
    }

    init(voice: any AgentPaneReadAloudVoice) {
        self.voice = voice
    }

    /// A page's request.
    public nonisolated enum Command: Hashable, Sendable {
        /// `readAloud.speak {id, text, lang?}`: read message `id`, stopping whatever reads.
        case speak(id: String, text: String, language: String?)
        /// `readAloud.stop`: stop whatever reads.
        case stop

        /// Longest text read (a long answer is far shorter).
        static let maximumText = 200_000

        init?(method: String, params: [String: Any]?) {
            switch method {
            case "readAloud.stop": self = .stop
            case "readAloud.speak":
                guard let id = params?["id"] as? String, !id.isEmpty, id.utf8.count <= 256,
                      let text = params?["text"] as? String, !text.isEmpty, text.count <= Self.maximumText else { return nil }
                let lang = (params?["lang"] as? String).flatMap { !$0.isEmpty && $0.count <= 35 ? $0 : nil }
                self = .speak(id: id, text: text, language: lang)
            default: return nil
            }
        }
    }

    private let voice: any AgentPaneReadAloudVoice
    /// The message read now and the chat that asked; nil while nothing reads.
    private var current: (id: String, owner: ObjectIdentifier, utterance: Int)?
    private var utterances = 0
    /// Called on every change of what reads.
    var onChange: (() -> Void)?
    /// The pages pushed so far, held weakly, for the pushes on a change.
    private let views = NSHashTable<AgentPaneView>.weakObjects()

    /// Whether anything reads now.
    public var isReading: Bool { current != nil }

    /// Reads `text` as message `id` for `owner`'s chat, stopping whatever read before.
    func speak(_ text: String, id: String, language: String?, owner: AnyObject) {
        if current != nil { voice.stop() }
        utterances += 1
        let utterance = utterances
        current = (id, ObjectIdentifier(owner), utterance)
        voice.speak(text, language: language) { [weak self] in
            // A cut-off utterance ends late: only the one read now clears the state.
            guard let self, self.current?.utterance == utterance else { return }
            self.current = nil
            self.changed()
        }
        changed()
    }

    /// Stops whatever reads, from any chat; false when nothing did.
    @discardableResult
    public func stop() -> Bool {
        guard current != nil else { return false }
        current = nil
        voice.stop()
        changed()
        return true
    }

    /// Stops the reading `owner`'s chat started (the chat closed); another chat's reads on.
    func stop(owner: AnyObject) {
        guard current?.owner == ObjectIdentifier(owner) else { return }
        stop()
    }

    /// The message `owner`'s chat reads now, nil for none.
    func reading(for owner: AnyObject) -> String? {
        guard let current, current.owner == ObjectIdentifier(owner) else { return nil }
        return current.id
    }

    /// The `readAloud` event for `owner`'s page: `{id}`, the message it reads or null.
    func event(for owner: AnyObject) -> AgentPageEvent {
        AgentPageEvent(kind: "readAloud", value: .object(["id": reading(for: owner).map(JSONValue.string) ?? .null]))
    }

    /// The event for `view`'s page, read now; `view` then also gets every change.
    func event(for view: AgentPaneView) -> AgentPageEvent {
        views.add(view)
        return event(for: view.model as AnyObject)
    }

    /// Pushes the state to `view`'s page; `view` then also gets every change.
    func push(to view: AgentPaneView) {
        views.add(view)
        send(to: view)
    }

    private func send(to view: AgentPaneView) {
        let event = event(for: view.model as AnyObject)
        view.deliver([event], scripts: ["window.cmuxAcpmuxBridge?.applyReadAloud?.(\(event.value.compactText));"])
    }

    private func changed() {
        for view in views.allObjects { send(to: view) }
        onChange?()
    }
}
