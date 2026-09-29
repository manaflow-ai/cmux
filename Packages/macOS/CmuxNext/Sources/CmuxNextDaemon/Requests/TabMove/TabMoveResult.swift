import Foundation

// Tab drag commits (plans/cmux-next/REWRITE.md "Tab drag"): every drop
// outcome is ONE daemon command, atomic and undoable. Each carries an
// optional client transaction id that the daemon echoes in the resulting
// delta, so the App can apply the move optimistically at drop time and
// reconcile when `DaemonStore` reports the echo.
//
// TODO(feat-cmux-next-daemon): `tab-to-new-split`, `tab-to-new-column`,
// `tab-to-new-workspace`, and the `client_transaction_id` field/echo are being
// added on that branch; names here are the proposed ones. Current daemons
// reject the new commands with "unknown variant", which the convenience API
// maps to `DaemonError.missingCapabilities`, and ignore the id on
// `move-tab` / `move-tab-to-workspace`.

/// Lenient result of a tab move: whichever placement fields the daemon returns.
public struct TabMoveResult: Decodable, Sendable, Equatable {
    public var surface: SurfaceID?
    public var pane: PaneID?
    public var screen: ScreenID?
    public var workspace: WorkspaceHandle?
    public var key: WorkspaceKey?
    public var clientTransactionID: ClientTransactionID?

    enum CodingKeys: String, CodingKey {
        case surface, pane, screen, workspace, key
        case clientTransactionID = "client_transaction_id"
    }
}

/// Edge drop zone of a pane.
public enum PaneEdge: String, Sendable, Hashable, Codable {
    case left, right, up, down
}
