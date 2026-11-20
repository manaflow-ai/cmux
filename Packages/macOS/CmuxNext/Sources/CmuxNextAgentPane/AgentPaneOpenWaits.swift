/// The waits for another process that a chat's open ran before its page drew the chat, as the
/// host sees them: from the moment a tab got its page (a page made for it, or the prewarmed page
/// it adopted) to the page's first `pane.painted`.
///
/// The target is a count, not a time: 0 for a chat whose kept tail the page draws on a connected
/// page, 1 at most on a connected page, whatever the chat's length. A page made for the tab runs
/// all of them in a row.
///
/// The host does not observe each wait. It sees 3 reports of the page and GIVES each a fixed
/// count (``Step/waits``: 3, 2, 1), so this number is the host's model of the page's waits, not
/// a measure of them. What the page asked acpmux in between is the page's to say
/// (`debug.agent_pane acp_log`); the count of a real page's open is the bench's (`open_waits` in
/// the pane's readiness, kept for each traced open).
public struct AgentPaneOpenWaits: Equatable, Sendable {
    public enum Step: String, CaseIterable, Sendable {
        /// The host answered a fresh page's `ready`: the page's process started, its document and
        /// bundle loaded, and the handshake went to the host and back.
        case handshake
        /// The page's acpmux client connected (`pane.clientReady`): the host opened the socket
        /// and acpmux answered `initialize`.
        case connected
        /// The page drew the chat without a kept tail: it read the chat from acpmux first.
        case attached

        /// The waits for another process this step stands for.
        public var waits: Int {
            switch self {
            case .handshake: 3
            case .connected: 2
            case .attached: 1
            }
        }
    }

    /// The steps that ran before the first paint, in order, each once.
    public private(set) var steps: [Step] = []
    /// The page drew: a later report is not part of the open.
    public private(set) var painted = false

    public init() {}

    /// The waits before the first paint.
    public var count: Int { steps.reduce(0) { $0 + $1.waits } }

    /// A step the page reported. Nothing after the first paint counts, and a step counts once.
    public mutating func ran(_ step: Step) {
        guard !painted, !steps.contains(step) else { return }
        steps.append(step)
    }

    /// The page's first paint: of a chat (`chat`) drawn from its kept tail or after a read from
    /// acpmux. A page with no chat (a New Tab page, a new chat) reads nothing to draw.
    public mutating func paint(chat: Bool, fromKeptTail: Bool) {
        if chat, !fromKeptTail { ran(.attached) }
        painted = true
    }
}
