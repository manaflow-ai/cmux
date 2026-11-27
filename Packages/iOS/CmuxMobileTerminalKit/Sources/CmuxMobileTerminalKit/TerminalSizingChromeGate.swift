/// Decides whether the shared-sizing chrome (border, hatch, cut-edge fades,
/// size chip) may draw on a terminal surface.
///
/// The chrome describes a settled mismatch between the shared grid and this
/// phone. It must not appear for a transient one: before the first size
/// state arrives, while the host's size state still lists an older viewport
/// of this phone, or while this phone has a viewport report queued or
/// awaiting its acknowledgement (keyboard, rotation, zoom, connect). Each of
/// those ends in a state or acknowledgement change, which re-evaluates the
/// gate, so no timer is needed.
public struct TerminalSizingChromeGate: Equatable, Sendable {
    /// This surface has a viewport report queued or awaiting its
    /// acknowledgement.
    public let viewportReportPending: Bool

    /// Creates a gate for the surface's current report state.
    /// - Parameter viewportReportPending: This surface has a viewport report
    ///   queued or awaiting its acknowledgement.
    public init(viewportReportPending: Bool) {
        self.viewportReportPending = viewportReportPending
    }

    /// Whether the chrome draws.
    /// - Parameter decoration: The published sizing facts, or `nil` before
    ///   the host published a size state.
    /// - Returns: `true` only for a settled mismatch.
    public func drawsChrome(decoration: TerminalSizingBoundsDecoration?) -> Bool {
        guard let decoration,
              decoration.viewportConfirmed,
              !viewportReportPending else {
            return false
        }
        return decoration.viewportDiffers
    }

    /// Whether the plain letterbox border (hosts without size states) draws.
    /// - Parameter isLetterboxed: The render is smaller than the viewport.
    /// - Returns: `true` only for a settled letterbox.
    public func drawsPlainLetterboxBorder(isLetterboxed: Bool) -> Bool {
        isLetterboxed && !viewportReportPending
    }
}
