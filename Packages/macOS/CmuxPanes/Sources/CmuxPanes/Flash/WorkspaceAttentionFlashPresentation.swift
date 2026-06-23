public import AppKit
public import CoreGraphics
public import CmuxCore
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

    /// The ring style flashed for a notification arrival (the steady unread
    /// indicator ring): a subtle blue glow. Faithful lift of the legacy
    /// presentation constant, now owned by the value type it produces instead of
    /// a no-case namespace enum.
    public static let notificationRing = WorkspaceAttentionFlashPresentation(
        accent: .notificationBlue,
        glowOpacity: 0.35,
        glowRadius: 3
    )

    /// The ring style flashed for an active attention pulse: a brighter, wider
    /// blue glow than ``notificationRing``.
    public static let flashRing = WorkspaceAttentionFlashPresentation(
        accent: .notificationBlue,
        glowOpacity: 0.6,
        glowRadius: 6
    )

    /// The ring style to flash for a given attention reason. Every current
    /// reason maps to ``flashRing``; the switch is retained so a future reason
    /// must consciously choose its style. Faithful lift of the legacy
    /// `WorkspaceAttentionCoordinator.flashStyle(for:)`.
    public static func flashRing(for reason: WorkspaceAttentionFlashReason) -> WorkspaceAttentionFlashPresentation {
        switch reason {
        case .navigation, .notificationArrival, .notificationDismiss, .unreadIndicatorDismiss, .debug:
            return flashRing
        }
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
