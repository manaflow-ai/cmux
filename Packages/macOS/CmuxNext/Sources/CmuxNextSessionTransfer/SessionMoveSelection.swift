public import CmuxNextDesign
import Foundation

/// The picker of Move Sessions from Another cmux Build… (cx-yxmkh) as data:
/// each build's name, then one check box per session (all checked), and the
/// sessions each build's checked boxes name. `CmuxDialogCenter` draws it;
/// `SessionMoveFromBuild` runs it.
public nonisolated struct SessionMoveSelection: Equatable {
    /// One session's check box.
    public struct Row: Equatable {
        /// The dialog field id of the row's check box.
        public let field: String
        /// The session's id in its build (`SessionTransferItem.id`).
        public let item: String
        /// The check box's title (``SessionMoveSelection/title(_:)``).
        public let title: String
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

    /// The builds that have sessions, in discovery order.
    public let groups: [Group]

    /// Lays out the picker for `peers`, leaving out a build with no sessions.
    /// - Parameter peers: The discovered builds.
    public init(peers: [SessionTransferPeer]) {
        groups = peers.enumerated().compactMap { index, peer in
            guard !peer.items.isEmpty else { return nil }
            let rows = peer.items.enumerated().map { row, item in
                Row(field: "session.\(index).\(row)", item: item.id, title: Self.title(item))
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

    /// The picker as a cmux dialog: each build's heading, then its sessions, all checked.
    public var dialog: CmuxDialogSpec {
        let fields = groups.flatMap { group -> [CmuxDialogField] in
            [.preview(group.heading)] + group.rows.map { .check(id: $0.field, title: $0.title, on: true) }
        }
        return CmuxDialogSpec(title: Self.dialogTitle, lines: [Self.dialogLine], fields: fields,
                              buttons: [.cancel(), CmuxDialogButton(id: Self.moveButton, title: Self.move, role: .default)],
                              identifier: "cmux.dialog.sessionMove")
    }

    /// The builds to pull from and the sessions each moves, in picker order.
    /// A build with nothing checked is left out: `pull` with no ids moves all of its sessions.
    public func pulls(checked: Set<String>) -> [Pull] {
        groups.compactMap { group in
            let ids = Set(group.rows.filter { checked.contains($0.field) }.map(\.item))
            return ids.isEmpty ? nil : Pull(source: group.source, heading: group.heading, ids: ids)
        }
    }

    /// The pulls a dialog answer asks for: none unless Move was pressed.
    public func pulls(_ answer: CmuxDialogAnswer) -> [Pull] {
        guard answer.button == Self.moveButton, !answer.isDismissal else { return [] }
        return pulls(checked: Set(answer.values.compactMap { $0.value.bool == true ? $0.key : nil }))
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
