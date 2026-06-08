import Foundation

/// A terminal size in character cells.
///
/// Attach has more than one party deciding how big a surface should be: the
/// GUI window's own layout and every bare terminal currently attached to it.
/// `SurfaceSize` is the value those parties exchange and `arbitrate(gui:attachments:)`
/// is the rule that reconciles them - the same "smallest screen wins" rule the
/// Go daemon already applies for remote PTYs, ported here so the app side can
/// reuse it without depending on the daemon.
public struct SurfaceSize: Sendable, Equatable, Codable {
    public var cols: Int
    public var rows: Int

    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }

    /// Whether both dimensions are positive. A zero or negative dimension means
    /// "unset" and is ignored by `arbitrate`, matching the daemon's convention.
    public var isPositive: Bool { cols > 0 && rows > 0 }

    /// The effective size for a surface given the GUI's own size and the sizes
    /// of every attached client.
    ///
    /// The rule is min-cols and min-rows across the GUI and all positive
    /// attachment sizes, so the surface never renders wider or taller than the
    /// smallest viewer can display. Attachment sizes that are unset (a
    /// non-positive dimension) are skipped. With no attachments the GUI size is
    /// returned unchanged, which is what restores the surface after the last
    /// client detaches.
    ///
    /// NOTE: not yet wired into the host. The single-viewer attach path mins
    /// against the GUI directly (see `SurfaceAttachBridge.applyAttachmentSize`);
    /// this is the primitive for the cross-viewer arbitration follow-up, which
    /// must reconcile attach with the GUI's `mobileViewportReportsBySurfaceID`.
    public static func arbitrate(gui: SurfaceSize, attachments: [SurfaceSize]) -> SurfaceSize {
        var cols = gui.cols
        var rows = gui.rows
        for attachment in attachments {
            if attachment.cols > 0 { cols = min(cols, attachment.cols) }
            if attachment.rows > 0 { rows = min(rows, attachment.rows) }
        }
        return SurfaceSize(cols: cols, rows: rows)
    }
}
