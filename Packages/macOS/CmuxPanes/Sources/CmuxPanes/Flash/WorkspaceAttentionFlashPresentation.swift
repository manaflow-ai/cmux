public import AppKit
public import CoreGraphics
public import CmuxTerminalCore

/// The accent palette used by a panel attention-flash ring.
public enum WorkspaceAttentionFlashAccent: Equatable, Sendable {
    case notificationBlue

    /// The AppKit stroke color this accent resolves to.
    public var strokeColor: NSColor {
        switch self {
        case .notificationBlue:
            return .systemBlue
        }
    }
}

/// The app-facing presentation half of attention flashing.
///
/// Carries the accent plus glow parameters and lowers them, together with the
/// shared ``PanelOverlayRingMetrics``, into the AppKit-free
/// ``TerminalPaneRingPresentation`` the terminal-surface overlay container
/// consumes. The pure flash *decision* lives in `CmuxCore`
/// (`WorkspaceAttentionPersistentState` / `WorkspaceAttentionFlashDecision`);
/// the ring colors/styles stay here because they resolve to `NSColor`.
public struct WorkspaceAttentionFlashPresentation: Equatable, Sendable {
    public let accent: WorkspaceAttentionFlashAccent
    public let glowOpacity: Double
    public let glowRadius: CGFloat

    public init(
        accent: WorkspaceAttentionFlashAccent,
        glowOpacity: Double,
        glowRadius: CGFloat
    ) {
        self.accent = accent
        self.glowOpacity = glowOpacity
        self.glowRadius = glowRadius
    }

    /// Lowers this presentation into the `Sendable` ring presentation consumed
    /// by the terminal-surface overlay container.
    ///
    /// Resolves the accent `NSColor` to straight sRGB components and folds in
    /// the shared ``PanelOverlayRingMetrics`` so the view layer never imports
    /// either the attention palette or the ring metrics.
    public func ringPresentation() -> TerminalPaneRingPresentation {
        let color = accent.strokeColor.usingColorSpace(.sRGB) ?? accent.strokeColor
        return TerminalPaneRingPresentation(
            red: Double(color.redComponent),
            green: Double(color.greenComponent),
            blue: Double(color.blueComponent),
            alpha: Double(color.alphaComponent),
            glowOpacity: glowOpacity,
            glowRadius: glowRadius,
            lineWidth: PanelOverlayRingMetrics.lineWidth,
            inset: PanelOverlayRingMetrics.inset,
            cornerRadius: PanelOverlayRingMetrics.cornerRadius
        )
    }
}
