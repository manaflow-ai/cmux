public import CmuxNextSettings
public import Foundation

/// Toggle Terminal and Chat's approval on the chat face (Leo, 2026-11-12: the terminal and GUI toggle
/// is "the sauce", two live views of one session, instant both ways). While the terminal drives the
/// session the chat is a View Only watch and acpmux sends it no permission: the harness asks in the
/// terminal. The App reads that dialog off the terminal's screen (cmux-window-rules `tabs::approval`)
/// and shows it here; the page draws it as the chat's own permission card (`terminalApproval` event,
/// webviews terminalApproval/terminalApproval.ts) and a click comes back as
/// `chat.terminalApproval.answer {key, label, id}`, which the host takes only with a real
/// gesture in the pane and only for the dialog it shows, then the App picks that option in the terminal.
public nonisolated struct AgentPaneTerminalApproval: Hashable, Sendable {
    public struct Option: Hashable, Sendable {
        public var key: Int
        public var label: String
        /// `allow_once`, `allow_always`, `reject_once` or `other`.
        public var kind: String

        public init(key: Int, label: String, kind: String) {
            self.key = key
            self.label = label
            self.kind = kind
        }
    }

    /// The person's pick: the option and the dialog it answers (its ``id``).
    public struct Pick: Hashable, Sendable {
        public var key: Int
        public var label: String
        /// ``AgentPaneTerminalApproval/id`` of the card clicked.
        public var id: String

        public init(key: Int, label: String, id: String) {
            self.key = key
            self.label = label
            self.id = id
        }
    }

    /// What the dialog asks, whole (cmux-window-rules `TerminalApproval::id`): a pick names it, so a click on a
    /// card answers only that dialog, never another asking the same question about another command.
    public var id: String
    public var question: String
    public var header: String?
    public var command: String?
    public var detail: [String]
    public var options: [Option]
    /// The terminal's harness (`claude`, `codex`), for the card's look.
    public var harness: String?

    public init(id: String, question: String, header: String? = nil, command: String? = nil, detail: [String] = [],
                options: [Option], harness: String? = nil) {
        self.id = id
        self.question = question
        self.header = header
        self.command = command
        self.detail = detail
        self.options = options
        self.harness = harness
    }

    /// The longest label or id a pick names, in UTF-8 bytes.
    static let maximumText = 2048

    var json: JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(id), "question": .string(question), "detail": .array(detail.map(JSONValue.string)),
            "options": .array(options.map { ["key": .number(Double($0.key)), "label": .string($0.label), "kind": .string($0.kind)] }),
        ]
        if let header { object["header"] = .string(header) }
        if let command { object["command"] = .string(command) }
        if let harness { object["harness"] = .string(harness) }
        return .object(object)
    }

    /// `chat.terminalApproval.answer {key, label, id}`, nil when the params break the contract.
    static func pick(_ params: [String: Any]?) -> Pick? {
        guard let params, Set(params.keys) == ["key", "label", "id"],
              let key = (params["key"] as? NSNumber)?.intValue, (1...99).contains(key),
              let label = params["label"] as? String, let id = params["id"] as? String,
              !label.isEmpty, label.utf8.count <= maximumText, !id.isEmpty, id.utf8.count <= maximumText else { return nil }
        return Pick(key: key, label: label, id: id)
    }
}

extension AgentPageEvent {
    /// The terminal's approval dialog for this chat (`terminalApproval`), null for none.
    static func terminalApproval(_ approval: AgentPaneTerminalApproval?) -> AgentPageEvent {
        AgentPageEvent(kind: "terminalApproval", value: approval?.json ?? .null)
    }
}

extension AgentPaneTerminalApproval {
    /// Shows `approval` (nil: none) on `view`'s page, a change only; the model keeps it for a page that loads later.
    /// Not an AgentPaneView extension: that type is at its size limit.
    @MainActor public static func show(_ approval: AgentPaneTerminalApproval?, on view: AgentPaneView) {
        guard approval != view.model.terminalApproval else { return }
        view.model.terminalApproval = approval
        replay(to: view)
    }

    /// Gives `view`'s page the dialog its model keeps (a page that just loaded).
    @MainActor static func replay(to view: AgentPaneView) {
        let event = AgentPageEvent.terminalApproval(view.model.terminalApproval)
        view.deliver([event], scripts: ["window.cmuxAcpmuxTerminalApproval?.(\(event.value.compactText));"])
    }

    /// The reply to the page's click: only for an option of the dialog shown, with a real gesture in the
    /// pane (page script cannot make one), then the App's answer (``AgentPaneModel/onTerminalApproval``),
    /// which fails when the terminal no longer shows that dialog.
    @MainActor static func respond(_ pick: Pick, in model: AgentPaneModel) async -> [String: Any] {
        guard let answer = model.onTerminalApproval, let shown = model.terminalApproval, shown.id == pick.id,
              shown.options.contains(where: { $0.key == pick.key && $0.label == pick.label }) else {
            return AgentPaneModel.unsupported("chat.terminalApproval.answer")
        }
        guard model.transport.gestures.consume() else { return AgentPaneModel.transportFailure(.gestureRequired) }
        guard await answer(pick) else {
            return AgentPaneReply.failure(code: "terminal_changed", message: "The terminal no longer asks this")
        }
        return AgentPaneReply.success()
    }
}
