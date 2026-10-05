import Foundation

/// The id and surface of a tab a create intent shows before the daemon has the tab: neither can
/// name a daemon tab.
public struct ProvisionalTab: Sendable, Hashable {
    /// The tab id prefix (`TabModel.id`) of a provisional tab.
    public static let idPrefix = "pending_tab_"
    /// Daemon surfaces count up from 1; provisional ones live far above them.
    private static let surfaceBase: UInt64 = 1 << 62
    @MainActor private static var next: UInt64 = 0

    /// The provisional tab's id (`TabModel.id`).
    public let id: String
    /// Its surface, far above every daemon surface.
    public let surface: SurfaceID

    /// A fresh provisional tab.
    @MainActor public init() {
        Self.next += 1
        id = Self.idPrefix + UUID().uuidString.lowercased()
        surface = SurfaceID(rawValue: Self.surfaceBase + Self.next)
    }

    public static func isProvisional(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    /// A create intent's reply named the daemon's tab `surface`: from now on the provisional tab
    /// shows only while the records lack that surface, so the two never show side by side.
    @MainActor public static func created(_ transaction: ClientTransactionID, surface: SurfaceID, in store: DaemonStore) {
        guard store.intentLog.contains(transaction) else { return }
        store.intentLog.noteCreated(transaction, surface: surface)
        if store.tabsBySurface[surface] != nil, !store.overlayLifted, store.applyDepth == 0 {
            store.withOverlayLifted(writer: "intent created") {}
        }
    }
}
