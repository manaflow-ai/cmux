public import CmuxNextDesign
public import CmuxNextSettings
import Foundation

/// The picker of Move Sessions from Another cmux Build… (cx-yxmkh) as data:
/// each build's name, then one check box per session, and the sessions each
/// build's checked boxes name. Moving a terminal opens a new shell here and
/// ends the terminal in its build (its program and scrollback), so a terminal
/// starts unchecked, one running a program (or whose build can't tell) has no
/// check box, and a move that ends one asks again (``endTerminalsDialog(for:)``)
/// with no Return default. Chats and agents start checked. `CmuxDialogCenter`
/// draws it; `SessionMoveFromBuild` runs it.
public nonisolated struct SessionMoveSelection: Equatable {
    /// One session's check box.
    public struct Row: Equatable {
        /// The dialog field id of the row's check box.
        public let field: String
        /// The session's id in its build (`SessionTransferItem.id`).
        public let item: String
        /// The check box's title (``SessionMoveSelection/title(_:)``).
        public let title: String
        /// What the session is: moving a terminal ends it in its build.
        public let kind: SessionTransferItem.Kind
        /// Why the row can't be checked (a terminal that runs a program, or whose build
        /// can't tell), as the dialog shows it in place of a check box; nil when it can.
        public let blocked: String?

        /// Whether the row's session is a terminal.
        public nonisolated var isTerminal: Bool { kind == .terminal }
    }

    /// One build: its heading, then its sessions' rows.
    public struct Group: Equatable {
        /// The build's socket path, what `SessionTransferService.pull` takes as `source`.
        public let source: String
        /// The build's heading (``SessionMoveSelection/heading(_:)``).
        public let heading: String
        /// The build's sessions, in the order it listed them.
        public let rows: [Row]
    }

    /// One build's checked sessions.
    public struct Pull: Equatable {
        /// The build's socket path.
        public let source: String
        /// The build's heading, for a failure that names it.
        public let heading: String
        /// The checked sessions' ids.
        public let ids: Set<String>

        /// Creates a pull of `ids` from build `source`.
        /// - Parameters:
        ///   - source: The build's socket path.
        ///   - heading: The build's heading.
        ///   - ids: The sessions to move.
        public init(source: String, heading: String, ids: Set<String>) {
            self.source = source
            self.heading = heading
            self.ids = ids
        }
    }

    /// The id of the dialog's Move button.
    public static let moveButton = "move"
    /// The id of the Move and End Terminals button of ``endTerminalsDialog(for:)``.
    public static let endTerminalsButton = "endTerminals"

    /// The builds that have sessions, in discovery order.
    public let groups: [Group]

    /// Lays out the picker for `peers`, leaving out a build with no sessions.
    /// - Parameter peers: The discovered builds.
    public init(peers: [SessionTransferPeer]) {
        groups = peers.enumerated().compactMap { index, peer in
            guard !peer.items.isEmpty else { return nil }
            let rows = peer.items.enumerated().map { row, item in
                let title = Self.title(item)
                return Row(field: "session.\(index).\(row)", item: item.id, title: title, kind: item.kind,
                           blocked: Self.blocked(item, title: title))
            }
            return Group(source: peer.path, heading: Self.heading(peer), rows: rows)
        }
    }

    /// Whether no build has a session to move.
    public var isEmpty: Bool { groups.isEmpty }

    /// Build `source`'s session titles by session id, for the toast (ids are unique only within a build).
    public func titles(in source: String) -> [String: String] {
        let rows = groups.filter { $0.source == source }.flatMap(\.rows)
        return Dictionary(rows.map { ($0.item, $0.title) }, uniquingKeysWith: { first, _ in first })
    }

    /// The picker as a cmux dialog: each build's heading, then its sessions. Chats and agents
    /// start checked, terminals unchecked; a blocked terminal is a line saying why, not a check box.
    public var dialog: CmuxDialogSpec {
        let fields = groups.flatMap { group -> [CmuxDialogField] in
            [.preview(group.heading)] + group.rows.map { row in
                row.blocked.map(CmuxDialogField.preview) ?? .check(id: row.field, title: row.title, on: !row.isTerminal)
            }
        }
        return CmuxDialogSpec(title: Self.dialogTitle, lines: [Self.dialogLine, Self.terminalLine], fields: fields,
                              buttons: [.cancel(), CmuxDialogButton(id: Self.moveButton, title: Self.move, role: .default)],
                              identifier: "cmux.dialog.sessionMove")
    }

    /// The builds to pull from and the sessions each moves, in picker order.
    /// A build with nothing checked is left out: `pull` with no ids moves all of its sessions.
    /// A blocked row never moves, whatever `checked` says.
    public func pulls(checked: Set<String>) -> [Pull] {
        groups.compactMap { group in
            let ids = Set(group.rows.filter { $0.blocked == nil && checked.contains($0.field) }.map(\.item))
            return ids.isEmpty ? nil : Pull(source: group.source, heading: group.heading, ids: ids)
        }
    }

    /// The pulls a dialog answer asks for: none unless Move was pressed.
    public func pulls(_ answer: CmuxDialogAnswer) -> [Pull] {
        guard answer.button == Self.moveButton, !answer.isDismissal else { return [] }
        return pulls(checked: Set(answer.values.compactMap { $0.value.bool == true ? $0.key : nil }))
    }

    /// The titles of the terminals `pulls` would move, which their builds end. Non-empty,
    /// the move waits for ``endTerminalsDialog(for:)``.
    public func terminals(in pulls: [Pull]) -> [String] {
        pulls.flatMap { pull in
            groups.filter { $0.source == pull.source }.flatMap(\.rows)
                .filter { $0.isTerminal && pull.ids.contains($0.item) }.map(\.title)
        }
    }

    /// The second question a move that ends `terminals` asks, naming them. Its confirm
    /// button, Move and End Terminals, is destructive and nothing is the Return default,
    /// so Return never ends a terminal; Escape cancels.
    public static func endTerminalsDialog(for terminals: [String]) -> CmuxDialogSpec {
        CmuxDialogSpec(title: endTerminalsTitle, lines: [terminalLine], fields: terminals.map(CmuxDialogField.preview),
                       buttons: [.cancel(), CmuxDialogButton(id: endTerminalsButton, title: moveAndEndTerminals, role: .destructive)],
                       identifier: "cmux.dialog.sessionMove.endTerminals")
    }

    /// Whether `answer` to ``endTerminalsDialog(for:)`` confirms ending the terminals.
    public static func confirmsEndingTerminals(_ answer: CmuxDialogAnswer) -> Bool {
        answer.button == endTerminalsButton && !answer.isDismissal
    }

    /// Why `item` can't be picked: a terminal that runs a program, or whose build can't tell.
    static func blocked(_ item: SessionTransferItem, title: String) -> String? {
        guard item.kind == .terminal else { return nil }
        switch item.activity {
        case .idle: return nil
        case .running(let program) where !program.isEmpty: return Self.running(title, program)
        case .running, .unknown: return Self.unknownActivity(title)
        }
    }

    /// Why a picked terminal must not move now, asked again right before its build ends it:
    /// the picker's answer is seconds or minutes old, and a terminal idle then may run `vim`
    /// now. `list` is the build's fresh `session.transfer.list` answer (nil when it gave none);
    /// a terminal missing from it, or whose build can't tell, does not move either. Nil: still idle.
    /// - Parameters:
    ///   - surface: The terminal's id in its build (`SessionTransferItem.id`).
    ///   - list: The build's `session.transfer.list` answer, if any.
    public static func handoffRefusal(surface: String, list: JSONValue?) -> String? {
        let item = (list?["sessions"]?.arrayValue ?? []).lazy.compactMap { SessionTransferItem(json: $0) }
            .first { $0.id == surface && $0.kind == .terminal }
        switch item?.activity ?? .unknown {
        case .idle: return nil
        case .running(let program) where !program.isEmpty: return becameBusy(program)
        case .running, .unknown: return becameUnknown
        }
    }

    /// The build's app name and, when it has one, its tag.
    public static func heading(_ peer: SessionTransferPeer) -> String {
        guard let tag = peer.tag, !tag.isEmpty, tag != peer.app else { return peer.app }
        return "\(peer.app) (\(tag))"
    }

    /// The session's title, else its folder's name, else what kind of session it is.
    public static func title(_ item: SessionTransferItem) -> String {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        if let cwd = item.cwd, !cwd.isEmpty { return (cwd as NSString).lastPathComponent }
        switch item.kind {
        case .terminal: return terminal
        case .agent, .chat: return agentChat
        }
    }

    /// Localized text: dialogTitle.
    public static var dialogTitle: String {
        String(localized: "sessionMove.dialog.title", defaultValue: "Move Sessions from Another cmux Build", bundle: .module)
    }
    /// Localized text: dialogLine.
    public static var dialogLine: String {
        String(localized: "sessionMove.dialog.line",
               defaultValue: "Each checked session opens here and closes in the build it came from.", bundle: .module)
    }
    /// Localized text: terminalLine.
    public static var terminalLine: String {
        String(localized: "sessionMove.dialog.terminalLine",
               defaultValue: "A moved terminal reopens here as a new shell, and its program and scrollback in the other build end.",
               bundle: .module)
    }
    /// Localized text: a terminal that can't move because it runs `program`.
    public static func running(_ title: String, _ program: String) -> String {
        String(localized: "sessionMove.row.running", defaultValue: "\(title): running \(program), so it stays in the other build.", bundle: .module)
    }
    /// Localized text: a terminal that can't move because its build can't tell whether a program runs in it.
    public static func unknownActivity(_ title: String) -> String {
        String(localized: "sessionMove.row.unknownActivity",
               defaultValue: "\(title): the other build can’t tell whether a program is running, so it stays there.", bundle: .module)
    }
    /// Localized text: a picked terminal that started running `program` before the move.
    public static func becameBusy(_ program: String) -> String {
        String(localized: "sessionMove.handoff.running",
               defaultValue: "It started running \(program) after you picked it, so it stayed in the other build.", bundle: .module)
    }
    /// Localized text: a picked terminal whose build could no longer tell whether a program runs in it.
    public static var becameUnknown: String {
        String(localized: "sessionMove.handoff.unknownActivity",
               defaultValue: "The other build could no longer tell whether a program is running in it, so it stayed there.", bundle: .module)
    }
    /// Localized text: endTerminalsTitle.
    public static var endTerminalsTitle: String {
        String(localized: "sessionMove.endTerminals.title", defaultValue: "End These Terminals in the Other Build?", bundle: .module)
    }
    /// Localized text: moveAndEndTerminals.
    public static var moveAndEndTerminals: String {
        String(localized: "sessionMove.endTerminals.move", defaultValue: "Move and End Terminals", bundle: .module)
    }
    /// Localized text: move.
    public static var move: String {
        String(localized: "sessionMove.dialog.move", defaultValue: "Move", bundle: .module)
    }
    /// Localized text: terminal.
    public static var terminal: String {
        String(localized: "sessionMove.row.terminal", defaultValue: "Terminal session", bundle: .module)
    }
    /// Localized text: agentChat.
    public static var agentChat: String {
        String(localized: "sessionMove.row.agentChat", defaultValue: "Agent chat", bundle: .module)
    }
}
