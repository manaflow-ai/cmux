public import CoreGraphics

/// How many pinned extension actions fit in a browser toolbar row (design
/// spec §3a-bis).
///
/// From the row width it reserves the navigation buttons, the omnibar's
/// minimum and the fixed trailing set (the Extensions button plus the cmux
/// accessories shown at this width); the pinned actions get what is left,
/// at most ``maximumVisible``. Pins that don't fit leave from the left, so
/// the newest pins stay next to the Extensions button, as in Chrome.
public struct BrowserExtensionToolbarBudget: Equatable, Sendable {
    /// Most pinned actions ever shown.
    public static let maximumVisible = 6

    /// The toolbar row's width in points.
    public var rowWidth: CGFloat
    /// The chrome scale (`BrowserChromeMetrics.scale`).
    public var scale: CGFloat
    /// The cmux accessory buttons shown after the extension cluster at this width (design mode, profile, theme, DevTools, More).
    public var trailingAccessoryCount: Int

    /// Creates a budget.
    public init(rowWidth: CGFloat, scale: CGFloat, trailingAccessoryCount: Int) {
        self.rowWidth = rowWidth
        self.scale = scale
        self.trailingAccessoryCount = trailingAccessoryCount
    }

    // Base sizes at scale 1 (BrowserChromeMetrics and the toolbar row).
    static let navigationButton: CGFloat = 26
    static let omnibarMinimum: CGFloat = 200
    static let accessoryButton: CGFloat = 22
    static let accessorySpacing: CGFloat = 2
    static let groupGap: CGFloat = 6
    static let rowPadding: CGFloat = 8
    static let rowSpacing: CGFloat = 8

    /// The number of pinned actions that fit, at most `pinnedCount` and ``maximumVisible``.
    ///
    /// - Parameter pinnedCount: The extensions pinned in Chromium.
    public func visibleCount(pinnedCount: Int) -> Int {
        let slot = (Self.accessoryButton + Self.accessorySpacing) * scale
        let reserved = (Self.rowPadding * 2 + Self.navigationButton * 3 + Self.rowSpacing * 2 + Self.omnibarMinimum
            + Self.groupGap) * scale
            + CGFloat(trailingAccessoryCount + 1) * slot
        let remaining = rowWidth - reserved
        guard remaining > 0, slot > 0 else { return 0 }
        return min(Int((remaining / slot).rounded(.down)), Self.maximumVisible, max(pinnedCount, 0))
    }

    /// Splits pinned ids (Chromium's toolbar order, oldest first) into the shown ones and the overflowed ones.
    ///
    /// - Parameter pinned: The pinned extension ids in toolbar order.
    /// - Returns: The ids to show (the newest that fit) and the ids that overflow into the Extensions popover.
    public func split(_ pinned: [String]) -> (visible: [String], overflowed: [String]) {
        let count = visibleCount(pinnedCount: pinned.count)
        let cut = pinned.count - count
        return (Array(pinned.suffix(count)), Array(pinned.prefix(cut)))
    }
}
