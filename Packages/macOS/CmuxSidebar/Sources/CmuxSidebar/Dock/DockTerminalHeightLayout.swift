public import CoreGraphics

/// The vertical-space policy that divides a Dock panel's available height among
/// its stacked control terminals.
///
/// A pure value: it owns the fixed chrome metrics (`headerHeight`,
/// `dividerHeight`) and the `minimumTerminalHeight` floor, and computes a
/// per-control terminal height from a list of ``DockControlSnapshot`` and the
/// total height the panel was given. Controls with a `requestedHeight` are
/// pinned to that height (clamped up to `minimumTerminalHeight`); the leftover
/// space is split evenly across the flexible controls, or, when every control
/// is fixed, distributed across all of them. The layout view holds one of these
/// and reads `dividerHeight` for the inter-control separator, so the height math
/// and the rendered chrome share a single source of truth.
public struct DockTerminalHeightLayout: Sendable {
    /// Height reserved for each control's header row.
    public let headerHeight: CGFloat
    /// Height of the separator drawn between adjacent controls.
    public let dividerHeight: CGFloat
    /// Smallest terminal height a control is ever sized to.
    public let minimumTerminalHeight: CGFloat

    /// Creates a Dock terminal-height layout policy.
    ///
    /// The defaults match the production Dock chrome: a 30pt header, a 1pt
    /// divider, and a 160pt minimum terminal height.
    public init(
        headerHeight: CGFloat = 30,
        dividerHeight: CGFloat = 1,
        minimumTerminalHeight: CGFloat = 160
    ) {
        self.headerHeight = headerHeight
        self.dividerHeight = dividerHeight
        self.minimumTerminalHeight = minimumTerminalHeight
    }

    /// Computes the terminal height for each control given the panel's total
    /// available height.
    ///
    /// Returns an array parallel to `snapshots`. Fixed-height controls take
    /// `max(requestedHeight, minimumTerminalHeight)`; the remaining space (after
    /// subtracting header and divider chrome) is divided evenly among the
    /// flexible controls at no less than `minimumTerminalHeight` each, or, when
    /// no control is flexible, spread across all controls. Returns an empty
    /// array when there are no controls.
    public func terminalHeights(availableHeight: CGFloat, snapshots: [DockControlSnapshot]) -> [CGFloat] {
        guard !snapshots.isEmpty else { return [] }

        let chromeHeight = CGFloat(snapshots.count) * headerHeight
            + CGFloat(max(snapshots.count - 1, 0)) * dividerHeight
        let availableTerminalHeight = max(availableHeight - chromeHeight, 0)
        var heights = Array(repeating: CGFloat.zero, count: snapshots.count)
        var flexibleIndexes: [Int] = []
        var fixedHeightTotal: CGFloat = 0

        for (index, snapshot) in snapshots.enumerated() {
            if let requestedHeight = snapshot.requestedHeight {
                let fixedHeight = max(CGFloat(requestedHeight), minimumTerminalHeight)
                heights[index] = fixedHeight
                fixedHeightTotal += fixedHeight
            } else {
                flexibleIndexes.append(index)
            }
        }

        if flexibleIndexes.isEmpty {
            let extraHeight = max(availableTerminalHeight - fixedHeightTotal, 0)
            guard extraHeight > 0 else { return heights }
            let extraHeightPerControl = extraHeight / CGFloat(snapshots.count)
            return heights.map { $0 + extraHeightPerControl }
        }

        let remaining = max(availableTerminalHeight - fixedHeightTotal, 0)
        let sharedHeight = max(remaining / CGFloat(flexibleIndexes.count), minimumTerminalHeight)
        for index in flexibleIndexes {
            heights[index] = sharedHeight
        }

        return heights
    }
}
