/// The file and viewer open rules and the appearance verbs (cmux-window-rules `files`, `appearance`).
extension WindowRules {
    /// What an open decided: `decision` names it; the other fields are that decision's.
    public nonisolated struct Open: Decodable, Equatable, Sendable {
        /// markdown: `open`, `picker`, `refused`; diff: `chatPatch`, `folder`, `picker`, `refused`;
        /// VS Code: `panel`, `serve`, `thisMacOnly`, `notInstalled`, `noFolder`;
        /// Open With: `app`, `choose`, `noSuchApp`, `noSelection`.
        public var decision: String
        /// Markdown: `remote`, `besideChat` or `pane`.
        public var place: String?
        public var path: String?
        public var folder: String?
        public var focus: Bool?
        public var app: String?
        /// `pathNotAbsolute` or `pickerNeedsFocus`.
        public var refusal: String?
    }

    /// Open Markdown File.
    public func openMarkdown(path: String?, local: Bool, showsChat: Bool, allowsViewChange: Bool) -> Open? {
        struct Request: Encodable { var path: String?, local: Bool, showsChat: Bool, allowsViewChange: Bool }
        return call("window_files_open_markdown", Request(path: path, local: local, showsChat: showsChat, allowsViewChange: allowsViewChange),
                    as: Open.self)
    }

    /// Open Diff Viewer.
    public nonisolated struct DiffAsk: Encodable, Equatable, Sendable {
        public var patch: Bool, path: String?, paneFolder: String?, allowsViewChange: Bool, besideCaller: Bool
        public init(patch: Bool, path: String?, paneFolder: String?, allowsViewChange: Bool, besideCaller: Bool) {
            (self.patch, self.path, self.paneFolder, self.allowsViewChange, self.besideCaller) = (patch, path, paneFolder, allowsViewChange, besideCaller)
        }
    }

    public func openDiff(_ ask: DiffAsk) -> Open? {
        call("window_files_open_diff", ask, as: Open.self)
    }

    /// A diff of the pane's folder did not open: `reason`, `picker` or `pickerNeedsFocus`.
    public func diffFailed(local: Bool, allowsViewChange: Bool) -> String? {
        struct Request: Encodable { var local: Bool, allowsViewChange: Bool }
        struct Reply: Decodable { var failed: String }
        return call("window_files_diff_failed", Request(local: local, allowsViewChange: allowsViewChange), as: Reply.self)?.failed
    }

    /// A code editor page action; `runsEditorCommand`: it is named by its `text` argument.
    public nonisolated struct EditorAction: Encodable, Equatable, Sendable {
        public var action: String, runsEditorCommand: Bool
        public init(action: String, runsEditorCommand: Bool) {
            self.action = action
            self.runsEditorCommand = runsEditorCommand
        }
    }

    public nonisolated struct EditorBinding: Decodable, Equatable, Sendable {
        public var action: String
        /// The run is refused without a `text` argument.
        public var needsText: Bool
    }

    /// The editor actions the file page handler binds (every one but the shared find actions).
    public func editorBindings(_ actions: [EditorAction]) -> [EditorBinding]? {
        struct Request: Encodable { var actions: [EditorAction] }
        struct Reply: Decodable { var bindings: [EditorBinding] }
        return call("window_files_editor_bindings", Request(actions: actions), as: Reply.self)?.bindings
    }

    /// What Open Folder in VS Code (Inline) reads.
    public nonisolated struct VSCodeFacts: Encodable, Equatable, Sendable {
        public var local: Bool, installed: Bool, byPerson: Bool, terminal: Bool, cwd: String?
        public init(local: Bool, installed: Bool, byPerson: Bool, terminal: Bool, cwd: String?) {
            (self.local, self.installed, self.byPerson, self.terminal, self.cwd) = (local, installed, byPerson, terminal, cwd)
        }
    }

    public func vscodeOpen(_ facts: VSCodeFacts) -> Open? {
        call("window_files_vscode", facts, as: Open.self)
    }

    /// The file explorer's Open With.
    public func openWith(app: String?, byPerson: Bool, selection: Bool) -> Open? {
        struct Request: Encodable { var app: String?, byPerson: Bool, selection: Bool }
        return call("window_files_open_with", Request(app: app, byPerson: byPerson, selection: selection), as: Open.self)
    }

    /// An `appearance.set|reset` run (Rust owns the levels each property is set at).
    public nonisolated struct AppearanceAsk: Encodable, Equatable, Sendable {
        public var scope: String?, property: String?, set: Bool
        public init(scope: String?, property: String?, set: Bool) {
            (self.scope, self.property, self.set) = (scope, property, set)
        }
    }

    /// What an appearance verb does: `refusal` (`badProperty`, `notAtLevel`), else the level, the theme
    /// action its theme goes through, and the properties it writes (only those set at the level).
    public nonisolated struct AppearanceVerb: Decodable, Equatable, Sendable {
        public var refusal: String?
        public var level: String?
        public var themeAction: String?
        public var properties: [String]?
    }

    public func appearance(_ ask: AppearanceAsk) -> AppearanceVerb? {
        call("window_appearance_verb", ask, as: AppearanceVerb.self)
    }

    /// One cmux.json edit of a focus ring style: its path and a text or flag value.
    public nonisolated struct RingEdit: Decodable, Equatable, Sendable {
        public var path: [String]
        public var text: String?
        public var flag: Bool?

        private enum CodingKeys: String, CodingKey { case path, value }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            path = try container.decode([String].self, forKey: .path)
            flag = try? container.decode(Bool.self, forKey: .value)
            text = flag == nil ? try container.decode(String.self, forKey: .value) : nil
        }
    }

    /// Choosing a focus ring style (it also turns a ring that was off on).
    public func focusRingStyle(_ style: String, wasEnabled: Bool) -> [RingEdit]? {
        struct Request: Encodable { var style: String, wasEnabled: Bool }
        struct Reply: Decodable { var edits: [RingEdit] }
        return call("window_appearance_focus_ring_style", Request(style: style, wasEnabled: wasEnabled), as: Reply.self)?.edits
    }

    /// The Base Keymap toast: its lines (`title`, `noChanges`, `iTerm2Numbers`), Undo, its seconds.
    public nonisolated struct KeymapToast: Decodable, Equatable, Sendable {
        public var lines: [String]
        public var undo: Bool
        public var seconds: Int
    }

    public func keymapToast(preset: String, changed: [String]) -> KeymapToast? {
        struct Request: Encodable { var preset: String, changed: [String] }
        return call("window_appearance_keymap_toast", Request(preset: preset, changed: changed), as: KeymapToast.self)
    }
}
