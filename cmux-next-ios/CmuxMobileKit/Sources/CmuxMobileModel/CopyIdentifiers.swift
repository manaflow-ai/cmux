import Foundation

/// The Mac's Copy rows for a workspace and a tab (Copy Workspace ID, Copy Workspace ID and Ref,
/// Copy Workspace Link, Copy Tab ID, Copy Tab Link, Copy Pane ID, Copy Pane Link, Copy IDs), with
/// the Mac's exact text (`TabHandlers.bindIdentifiers`, `AppServices.link`): `key=value` lines
/// with the public ids the `cmux` CLI resolves (`ws_…`, `pane_…`, `tab_…`), and links in the
/// grammar Chief writes (`cmux://<kind>/<id>`). Each is nil when the Mac's tree did not carry the
/// id, so the phone offers no row it cannot fill.
extension Workspace {
    /// The `ws_` id, when the Mac sent one a link can carry.
    var publicID: String? { resourceID.flatMap { $0.hasPrefix("ws_") && ChiefMessageAbout.isLinkID($0) ? $0 : nil } }

    /// Copy Workspace ID: `workspace_id=ws_…`.
    public var copyIDText: String? { publicID.map { "workspace_id=\($0)" } }

    /// Copy Workspace ID and Ref: its `--target` form first.
    public var copyIDAndRefText: String? { publicID.map { "workspace_ref=workspace:\($0)\nworkspace_id=\($0)" } }

    /// Copy Workspace Link: `cmux://workspace/ws_…`.
    public var copyLinkText: String? { publicID.map { "cmux://workspace/\($0)" } }
}

extension WorkspaceTab {
    private static func linkID(_ id: String?, prefix: String) -> String? {
        id.flatMap { $0.hasPrefix(prefix) && ChiefMessageAbout.isLinkID($0) ? $0 : nil }
    }

    /// Copy Tab ID: `surface_id=tab_…`.
    public var copyIDText: String? { Self.linkID(linkIDs?.tab, prefix: "tab_").map { "surface_id=\($0)" } }

    /// Copy Pane ID: `pane_id=pane_…`.
    public var copyPaneIDText: String? { Self.linkID(linkIDs?.pane, prefix: "pane_").map { "pane_id=\($0)" } }

    /// Copy Pane Link: `cmux://pane/pane_…`.
    public var copyPaneLinkText: String? { Self.linkID(linkIDs?.pane, prefix: "pane_").map { "cmux://pane/\($0)" } }

    /// Copy Tab Link: `cmux://tab/tab_…`; an agent tab's is its chat's acpmux session,
    /// `cmux://session/<id>` (nil while the chat has none), as on the Mac.
    public var copyLinkText: String? {
        if kind == .agent {
            guard let session = linkIDs?.agentSession, !session.isEmpty,
                  session.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" })
            else { return nil }
            return "cmux://session/\(session)"
        }
        return Self.linkID(linkIDs?.tab, prefix: "tab_").map { "cmux://tab/\($0)" }
    }

    /// Copy IDs: the workspace, pane and tab ids, one per line, as far as the Mac sent them.
    public func copyIDsText(in workspace: Workspace) -> String? {
        let lines = [workspace.copyIDText, copyPaneIDText, copyIDText].compactMap(\.self)
        return copyIDText == nil ? nil : lines.joined(separator: "\n")
    }
}
