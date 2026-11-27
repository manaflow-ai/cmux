/// One item of a workspace checklist (`WorkspaceChecklistItem`).
public struct WorkspaceChecklistItem: Sendable, Hashable, Decodable, Identifiable {
    /// Where an item is.
    public enum State: String, Sendable, Hashable, Decodable, CaseIterable {
        /// Not started.
        case todo
        /// Being worked on.
        case inProgress = "in_progress"
        /// Finished.
        case done

        /// The state a Toggle Complete leaves the item in: done, or to do again for a done item.
        public var togglingComplete: State { self == .done ? .todo : .done }
    }

    /// Who created an item.
    public enum Origin: String, Sendable, Hashable, Decodable {
        /// A person (the app, the CLI in a plain shell).
        case user
        /// An agent (a process in a cmux terminal or an ACP session).
        case agent
    }

    /// The daemon's id of the item (`chk_…`).
    public var id: String
    /// The trimmed text (at most 500 characters).
    public var text: String
    /// Where the item is.
    public var state: State
    /// Who created it.
    public var origin: Origin
    /// The images attached to it, in order.
    public var attachments: [WorkspaceChecklistAttachment]

    /// Creates an item.
    /// - Parameters:
    ///   - id: The daemon's id.
    ///   - text: The item's text.
    ///   - state: Where the item is; to do by default.
    ///   - origin: Who created it; a person by default.
    ///   - attachments: Its images.
    public init(id: String, text: String, state: State = .todo, origin: Origin = .user,
                attachments: [WorkspaceChecklistAttachment] = []) {
        self.id = id
        self.text = text
        self.state = state
        self.origin = origin
        self.attachments = attachments
    }

    enum CodingKeys: String, CodingKey { case id, text, state, origin, attachments }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        // A state or origin a newer daemon adds reads as the nearest one this client knows.
        state = (try? c.decode(State.self, forKey: .state)) ?? .todo
        origin = (try? c.decode(Origin.self, forKey: .origin)) ?? .user
        attachments = (try? c.decode([WorkspaceChecklistAttachment].self, forKey: .attachments)) ?? []
    }
}
