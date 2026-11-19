import Foundation

/// Toggle Terminal and Chat's approval (cmux-window-rules `tabs::approval`): while a terminal drives
/// a session, the harness's own approval dialog on its screen shows in the paired chat and is
/// answered from it (Leo, 2026-11-12: two live views of one session, instant both ways).
extension WindowRules {
    /// A harness's numbered approval dialog read off a terminal's screen.
    public nonisolated struct TerminalApproval: Codable, Equatable, Sendable {
        /// What the dialog asks, whole (its question, heading, command, body and options, not the cursor):
        /// a click names it, and types nothing once the terminal shows another dialog.
        public var id: String
        public var question: String
        /// The dialog's heading ("Bash command", "Edit file").
        public var header: String?
        public var command: String?
        public var detail: [String]
        public var options: [Option]

        public nonisolated struct Option: Codable, Equatable, Sendable {
            /// The number the dialog draws before it.
            public var key: Int
            public var label: String
            public var hint: String?
            /// `allow_once`, `allow_always`, `reject_once` or `other`.
            public var kind: String
            public var selected: Bool

            public init(key: Int, label: String, hint: String? = nil, kind: String, selected: Bool) {
                self.key = key
                self.label = label
                self.hint = hint
                self.kind = kind
                self.selected = selected
            }
        }

        public init(id: String, question: String, header: String? = nil, command: String? = nil, detail: [String] = [],
                    options: [Option]) {
            self.id = id
            self.question = question
            self.header = header
            self.command = command
            self.detail = detail
            self.options = options
        }
    }

    private struct Screen: Encodable { var screen: String }
    private struct Read: Decodable { var approval: TerminalApproval? }
    private struct Answer: Encodable { var screen: String; var key: Int; var label: String; var id: String }
    private struct Keys: Decodable { var keys: [String]? }

    /// The approval dialog at the bottom of `screen` (a terminal's viewport, one line per row), or nil.
    public func terminalApproval(screen: String) -> TerminalApproval? {
        call("window_tabs_terminal_approval", Screen(screen: screen), as: Read.self)?.approval
    }

    /// The keys that pick option `key` (labelled `label`) of dialog `id` (``TerminalApproval/id``) on `screen` now,
    /// arrows then Enter; nil when the screen no longer shows that dialog with that option.
    public func terminalApprovalKeys(screen: String, key: Int, label: String, id: String) -> [String]? {
        call("window_tabs_terminal_approval_keys", Answer(screen: screen, key: key, label: label, id: id), as: Keys.self)?.keys
    }
}
