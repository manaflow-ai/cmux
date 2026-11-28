import Foundation

extension SetColumnDockRequest {
    /// Docks the column holding `pane` as `dock` says (its edge, mode and role), or undocks it when `dock` is nil.
    /// `pinned` nil keeps the column's pin (the daemon never clears one).
    public init(pane: PaneID, dock: DockSnapshot?, pinned: Bool? = nil, transaction: UInt64? = nil) {
        self.init(pane: pane, dock: dock != nil, edge: dock?.edge.rawValue, mode: dock?.mode.rawValue,
                  role: dock?.role?.rawValue, pinned: pinned, transaction: transaction)
    }
}
