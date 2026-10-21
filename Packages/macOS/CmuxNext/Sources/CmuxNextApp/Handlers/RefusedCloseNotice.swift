import AppKit

/// A close the daemon refused, shown to the user who asked for it: a beep
/// and the refusal HUD. A permanent docked column says it stays docked.
@MainActor
struct RefusedCloseNotice {
    /// cmux-tui's `error_code` for a close that would remove a permanent
    /// docked column (`permanent-dock-v1`, PERMANENT_COLUMN_CODE).
    static let permanentColumnCode = "dock-column-permanent"
    /// cmux-tui's `error_code` for a close of a pinned column's first tab
    /// (Home's tab, `pinned-dock-v1`, PINNED_COLUMN_CODE).
    static let pinnedColumnCode = "dock-column-pinned"

    let services: AppServices

    static func reason(codes: [String]) -> String {
        if codes.contains(pinnedColumnCode) { return RefusalStrings.homeTabStays }
        return codes.contains(permanentColumnCode) ? RefusalStrings.columnStaysDocked : RefusalStrings.closeRefused
    }

    func show(codes: [String], in window: NSWindow?) {
        NSSound.beep()
        services.refusalHUD.show(Self.reason(codes: codes), in: window)
    }
}
