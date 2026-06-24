public import AppKit

/// Immutable geometry snapshot of the titlebar controls accessory layout.
///
/// The accessory view controller stores the last applied snapshot and compares
/// the next computed one against it (within a small tolerance) to decide whether
/// a relayout is worth applying. All comparison predicates live here as members
/// so there is one owner for the tolerance math.
public struct TitlebarControlsLayoutSnapshot: Equatable, Sendable {
    public let contentSize: NSSize
    public let containerHeight: CGFloat
    public let xOffset: CGFloat
    public let yOffset: CGFloat

    public init(
        contentSize: NSSize,
        containerHeight: CGFloat,
        xOffset: CGFloat,
        yOffset: CGFloat
    ) {
        self.contentSize = contentSize
        self.containerHeight = containerHeight
        self.xOffset = xOffset
        self.yOffset = yOffset
    }

    /// Whether button-hover tracking should be applied at all. Always on; kept
    /// as a named predicate so the call site reads intentionally.
    public static var shouldTrackButtonHover: Bool { true }

    /// Whether a view-size change is large enough to schedule a size update.
    ///
    /// Returns `false` when the current size is degenerate, `true` on the first
    /// non-degenerate size, and otherwise compares width/height against the
    /// tolerance.
    public static func shouldScheduleForViewSizeChange(
        previous: NSSize,
        current: NSSize,
        tolerance: CGFloat = 0.5
    ) -> Bool {
        guard current.width > 0, current.height > 0 else { return false }
        guard previous.width > 0, previous.height > 0 else { return true }
        return abs(previous.width - current.width) > tolerance
            || abs(previous.height - current.height) > tolerance
    }

    /// Whether the next layout snapshot differs enough from the previous one to
    /// be worth applying. A nil previous always applies.
    public static func shouldApply(
        previous: TitlebarControlsLayoutSnapshot?,
        next: TitlebarControlsLayoutSnapshot,
        tolerance: CGFloat = 0.5
    ) -> Bool {
        guard let previous else { return true }
        return abs(previous.contentSize.width - next.contentSize.width) > tolerance
            || abs(previous.contentSize.height - next.contentSize.height) > tolerance
            || abs(previous.containerHeight - next.containerHeight) > tolerance
            || abs(previous.xOffset - next.xOffset) > tolerance
            || abs(previous.yOffset - next.yOffset) > tolerance
    }
}
