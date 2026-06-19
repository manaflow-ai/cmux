public import CoreGraphics

/// Pure width-clamp policy for the left workspace sidebar and the right file
/// explorer divider.
///
/// The two sidebar dividers each have their own clamp rule. The left sidebar is
/// clamped between a configurable minimum and a maximum derived from the window
/// width; the right file explorer is clamped between a fixed minimum and the
/// smaller of a configured/built-in cap and the width that still leaves a
/// minimum terminal column. Both rules sanitize non-finite inputs (NaN /
/// infinity) to a stable fallback so a corrupt persisted width can never produce
/// a degenerate layout.
///
/// This is the math half of the sidebar resizer cluster, extracted from the
/// app's `ContentView` as a faithful byte-identical lift. It holds the fixed
/// policy constants as instance state (constructor-injected so tests can pin
/// them and the production composition root supplies the real values), and
/// exposes the two clamp transforms as instance methods. The live resizer state
/// (drag width, hover set, pointer monitor, cursor stabilizer) stays in the
/// view and drives these transforms; nothing about the math touches AppKit,
/// SwiftUI, or window state.
public struct SidebarWidthPolicy: Sendable, Equatable {
    /// Fallback left-sidebar width used when a clamp candidate is non-finite
    /// (NaN / infinity). Mirrors `SessionPersistencePolicy.defaultSidebarWidth`
    /// at the composition root.
    public let defaultSidebarWidth: CGFloat

    /// Minimum width the right file explorer may shrink to.
    public let minimumRightSidebarWidth: CGFloat

    /// Built-in maximum right file explorer width, used when no configured
    /// maximum is supplied.
    public let maximumRightSidebarWidth: CGFloat

    /// Minimum terminal column width that must remain to the left of the right
    /// file explorer; the explorer is capped so this column always survives.
    public let minimumTerminalWidthWithRightSidebar: CGFloat

    /// Fallback right-sidebar width used when a clamp candidate is non-finite.
    public let rightSidebarFallbackWidth: CGFloat

    /// Fallback available width used when the supplied available width is
    /// non-finite or non-positive.
    public let rightSidebarFallbackAvailableWidth: CGFloat

    /// Creates a width policy from the fixed sidebar layout constants.
    /// - Parameters:
    ///   - defaultSidebarWidth: Left-sidebar fallback for non-finite candidates.
    ///   - minimumRightSidebarWidth: Hard floor for the right file explorer.
    ///   - maximumRightSidebarWidth: Built-in right-explorer cap.
    ///   - minimumTerminalWidthWithRightSidebar: Terminal column reserved beside
    ///     the right explorer.
    ///   - rightSidebarFallbackWidth: Right-explorer fallback for non-finite
    ///     candidates.
    ///   - rightSidebarFallbackAvailableWidth: Available-width fallback for
    ///     non-finite / non-positive available widths.
    public init(
        defaultSidebarWidth: CGFloat,
        minimumRightSidebarWidth: CGFloat,
        maximumRightSidebarWidth: CGFloat,
        minimumTerminalWidthWithRightSidebar: CGFloat,
        rightSidebarFallbackWidth: CGFloat = 220,
        rightSidebarFallbackAvailableWidth: CGFloat = 1920
    ) {
        self.defaultSidebarWidth = defaultSidebarWidth
        self.minimumRightSidebarWidth = minimumRightSidebarWidth
        self.maximumRightSidebarWidth = maximumRightSidebarWidth
        self.minimumTerminalWidthWithRightSidebar = minimumTerminalWidthWithRightSidebar
        self.rightSidebarFallbackWidth = rightSidebarFallbackWidth
        self.rightSidebarFallbackAvailableWidth = rightSidebarFallbackAvailableWidth
    }

    /// Clamps a proposed left-sidebar width between `minimumWidth` and a
    /// sanitized `maximumWidth`. A non-finite `maximumWidth` collapses to
    /// `minimumWidth`; a non-finite candidate falls back to
    /// ``defaultSidebarWidth`` clamped into range.
    /// - Parameters:
    ///   - candidate: The proposed sidebar width.
    ///   - maximumWidth: The window-derived maximum width.
    ///   - minimumWidth: The configured minimum sidebar width.
    /// - Returns: The clamped width.
    public func clampLeftSidebarWidth(
        _ candidate: CGFloat,
        maximumWidth: CGFloat,
        minimumWidth: CGFloat
    ) -> CGFloat {
        let sanitizedMaximumWidth = max(minimumWidth, maximumWidth.isFinite ? maximumWidth : minimumWidth)
        guard candidate.isFinite else {
            return max(
                minimumWidth,
                min(sanitizedMaximumWidth, defaultSidebarWidth)
            )
        }
        return max(minimumWidth, min(sanitizedMaximumWidth, candidate))
    }

    /// Clamps a proposed right file-explorer width. The effective maximum is the
    /// smaller of (the configured maximum, or the built-in maximum when none is
    /// configured) and the width that still leaves
    /// ``minimumTerminalWidthWithRightSidebar`` for the terminal column.
    /// Non-finite candidate / available widths fall back to
    /// ``rightSidebarFallbackWidth`` / ``rightSidebarFallbackAvailableWidth``.
    /// - Parameters:
    ///   - candidate: The proposed explorer width.
    ///   - availableWidth: The total content width available.
    ///   - configuredMaximumWidth: An optional user-configured maximum.
    /// - Returns: The clamped width.
    public func clampRightSidebarWidth(
        _ candidate: CGFloat,
        availableWidth: CGFloat,
        configuredMaximumWidth: CGFloat? = nil
    ) -> CGFloat {
        let minimumWidth = minimumRightSidebarWidth
        let sanitizedCandidate = candidate.isFinite ? candidate : rightSidebarFallbackWidth
        let sanitizedAvailableWidth = availableWidth.isFinite && availableWidth > 0
            ? availableWidth
            : rightSidebarFallbackAvailableWidth
        let availableWidthCap = max(
            minimumWidth,
            sanitizedAvailableWidth - minimumTerminalWidthWithRightSidebar
        )
        let configuredOrDefaultCap: CGFloat
        if let configuredMaximumWidth, configuredMaximumWidth.isFinite {
            configuredOrDefaultCap = max(minimumWidth, configuredMaximumWidth)
        } else {
            configuredOrDefaultCap = maximumRightSidebarWidth
        }
        let maximumWidth = min(configuredOrDefaultCap, availableWidthCap)
        return max(minimumWidth, min(maximumWidth, sanitizedCandidate))
    }
}
