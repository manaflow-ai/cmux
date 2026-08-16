/// Surface-scoped work requested when Ghostty vends a rendered frame.
///
/// The renderer keeps cursor-only updates separate from the shared
/// notification bus so a keyboard-copy overlay does not wake unrelated
/// observers.
public struct TerminalRenderedFrameDeliveryReasons: OptionSet, Sendable {
    /// Raw option bits.
    public let rawValue: UInt8

    /// Creates a reason set from raw option bits.
    ///
    /// - Parameter rawValue: Bitwise combination of known reasons.
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Publish the surface's shared rendered-frame notification.
    public static let notification = Self(rawValue: 1 << 0)

    /// Refresh only the surface's keyboard-copy cursor overlay.
    public static let keyboardCopyModeCursor = Self(rawValue: 1 << 1)

    /// cmux fork: (C) ExternalHover diagnostics — drain the surface's
    /// diagnostic ring on the next delivered frame. Demand-gated: a
    /// surface only retains this while it has an unresolved hover
    /// activation whose first render-validation entry hasn't been
    /// recovered yet (design-hover-diagnostics-v4-final.md §3.4's
    /// "render 後" trigger) — see `GhosttyNSView`'s
    /// `setExternalHoverDiagnosticsRenderTrackingActive`.
    public static let externalHoverDiagnostics = Self(rawValue: 1 << 2)
}
