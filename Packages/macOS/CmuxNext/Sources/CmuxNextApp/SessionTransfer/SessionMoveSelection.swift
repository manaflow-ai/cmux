import CmuxNextDesign
import Foundation

/// The picker of Move Sessions from Another cmux Build… (cx-yxmkh) as data:
/// each build's name, then one check box per session (all checked), and the
/// sessions each build's checked boxes name. `CmuxDialogCenter` draws it;
/// `SessionMoveFromBuild` runs it.
nonisolated struct SessionMoveSelection: Equatable {
    struct Row: Equatable {
        /// The dialog field id of the row's check box.
        let field: String
        /// The session's id in its build (`SessionTransferItem.id`).
        let item: String
        let title: String
    }

    struct Group: Equatable {
        /// The build's socket path, what `SessionTransferService.pull` takes as `source`.
        let source: String
        let heading: String
        let rows: [Row]
    }

    /// One build's checked sessions.
    struct Pull: Equatable {
        let source: String
        let heading: String
        let ids: Set<String>
    }

    static let moveButton = "move"

    let groups: [Group]

    init(peers: [SessionTransferPeer]) {
        groups = peers.enumerated().compactMap { index, peer in
            guard !peer.items.isEmpty else { return nil }
            let rows = peer.items.enumerated().map { row, item in
                Row(field: "session.\(index).\(row)", item: item.id, title: Self.title(item))
            }
            return Group(source: peer.path, heading: Self.heading(peer), rows: rows)
        }
    }

    var isEmpty: Bool { groups.isEmpty }

    /// Build `source`'s session titles by session id, for the toast (ids are unique only within a build).
    func titles(in source: String) -> [String: String] {
        let rows = groups.filter { $0.source == source }.flatMap(\.rows)
        return Dictionary(rows.map { ($0.item, $0.title) }, uniquingKeysWith: { first, _ in first })
    }

    var dialog: CmuxDialogSpec {
        let fields = groups.flatMap { group -> [CmuxDialogField] in
            [.preview(group.heading)] + group.rows.map { .check(id: $0.field, title: $0.title, on: true) }
        }
        return CmuxDialogSpec(title: Self.dialogTitle, lines: [Self.dialogLine], fields: fields,
                              buttons: [.cancel(), CmuxDialogButton(id: Self.moveButton, title: Self.move, role: .default)],
                              identifier: "cmux.dialog.sessionMove")
    }

    /// The builds to pull from and the sessions each moves, in picker order.
    /// A build with nothing checked is left out: `pull` with no ids moves all of its sessions.
    func pulls(checked: Set<String>) -> [Pull] {
        groups.compactMap { group in
            let ids = Set(group.rows.filter { checked.contains($0.field) }.map(\.item))
            return ids.isEmpty ? nil : Pull(source: group.source, heading: group.heading, ids: ids)
        }
    }

    /// The pulls a dialog answer asks for: none unless Move was pressed.
    func pulls(_ answer: CmuxDialogAnswer) -> [Pull] {
        guard answer.button == Self.moveButton, !answer.isDismissal else { return [] }
        return pulls(checked: Set(answer.values.compactMap { $0.value.bool == true ? $0.key : nil }))
    }

    /// The build's app name and, when it has one, its tag.
    static func heading(_ peer: SessionTransferPeer) -> String {
        guard let tag = peer.tag, !tag.isEmpty, tag != peer.app else { return peer.app }
        return "\(peer.app) (\(tag))"
    }

    /// The session's title, else its folder's name, else what kind of session it is.
    static func title(_ item: SessionTransferItem) -> String {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        if let cwd = item.cwd, !cwd.isEmpty { return (cwd as NSString).lastPathComponent }
        switch item.kind {
        case .terminal: return terminal
        case .agent, .chat: return agentChat
        }
    }

    static var dialogTitle: String {
        String(localized: "sessionMove.dialog.title", defaultValue: "Move Sessions from Another cmux Build", bundle: .module)
    }
    static var dialogLine: String {
        String(localized: "sessionMove.dialog.line",
               defaultValue: "Each checked session opens here and closes in the build it came from.", bundle: .module)
    }
    static var move: String {
        String(localized: "sessionMove.dialog.move", defaultValue: "Move", bundle: .module)
    }
    static var terminal: String {
        String(localized: "sessionMove.row.terminal", defaultValue: "Terminal session", bundle: .module)
    }
    static var agentChat: String {
        String(localized: "sessionMove.row.agentChat", defaultValue: "Agent chat", bundle: .module)
    }
}
