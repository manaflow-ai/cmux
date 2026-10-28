import Foundation

/// One item of a workspace's checklist (`workspace-checklist-v1`): the hover card lists it with
/// a mark for its state, and the Todo page edits it.
public nonisolated struct SidebarChecklistItem: Identifiable, Hashable, Sendable {
    /// Where the item is in its work.
    public enum State: Hashable, Sendable {
        case todo, inProgress, done

        /// The SF Symbol the hover card draws for the state.
        public var symbol: String {
            switch self {
            case .todo: "circle"
            case .inProgress: "circle.lefthalf.filled"
            case .done: "checkmark.circle.fill"
            }
        }
    }

    /// The daemon's item id (`chk_…`).
    public var id: String
    public var text: String
    public var state: State
    /// How many images the item has.
    public var attachmentCount: Int

    public init(id: String, text: String, state: State, attachmentCount: Int = 0) {
        self.id = id
        self.text = text
        self.state = state
        self.attachmentCount = attachmentCount
    }
}
