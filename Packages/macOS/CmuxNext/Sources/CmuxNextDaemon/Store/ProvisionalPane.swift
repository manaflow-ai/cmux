import Foundation

/// A pane a split intent shows before the daemon has it (`split-client-keys-v1`). Its handle and
/// its tab's surface live far above the daemon's numeric ids, so neither can name a daemon
/// object; its public pane, tab and terminal ids are the client-minted ones the split request
/// sends, so the daemon's pane is recognized by its public id when it arrives.
public struct ProvisionalPane: Sendable, Hashable {
    /// Daemon pane handles count up from 1; provisional ones live far above them.
    private static let handleBase: UInt64 = 1 << 62
    @MainActor private static var next: UInt64 = 0

    /// The provisional pane's handle in the store.
    public let handle: PaneID
    /// `pane_<32 hex>`, sent as the split's `pane_id`.
    public let paneID: String
    /// `tab_<32 hex>`, sent as the split's `tab_id`.
    public let tabID: String
    /// The new terminal's host id (UUIDv4, 32 hex), sent as `terminal_id`.
    public let terminalID: String
    /// The surface of its provisional tab.
    public let surface: SurfaceID

    /// A fresh provisional pane with new client-minted ids.
    @MainActor public init() {
        Self.next += 1
        handle = PaneID(rawValue: Self.handleBase + Self.next)
        surface = ProvisionalTab().surface
        let hex = { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
        paneID = "pane_" + hex()
        tabID = "tab_" + hex()
        terminalID = hex()
    }
}
