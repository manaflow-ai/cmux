public import CoreGraphics

/// Where the shared-sizing chip sits on a terminal surface.
///
/// The chip must never cover grid content, and above all never the last row,
/// where the prompt and the cursor live. It goes in the letterbox outside the
/// displayed grid, trying in order: below the grid's trailing corner (a
/// top-pinned grid leaves its slack below), beside its last rows, then above
/// its trailing corner (a grid the keyboard slid up can leave room only
/// there). The viewport passed in ends at the dock, so the chip is never
/// placed under the keyboard. When the grid fills the viewport there is no letterbox,
/// so the chip shrinks to a compact pill at the viewport's top-trailing
/// corner, away from the last row.
public struct TerminalSizingChipPlacement: Equatable, Sendable {
    /// Which rule placed the chip.
    public enum Anchor: Equatable, Sendable {
        /// In the letterbox below the grid, trailing-aligned.
        case belowGrid
        /// In the letterbox after the grid's trailing edge, bottom-aligned.
        case besideGrid
        /// In the letterbox above the grid, trailing-aligned.
        case aboveGrid
        /// No letterbox: a compact pill at the viewport's top-trailing corner.
        case viewportTopTrailing
    }

    /// The default distance between the chip and the grid or viewport edge.
    public static let defaultInset: CGFloat = 6

    /// The chip's frame in the surface's coordinates.
    public let frame: CGRect
    /// Which rule placed the chip.
    public let anchor: Anchor

    /// Whether the chip shows its compact title.
    public var isCompact: Bool { anchor == .viewportTopTrailing }

    /// Places the chip.
    /// - Parameters:
    ///   - chipSize: The full chip's fitting size.
    ///   - compactChipSize: The compact pill's fitting size.
    ///   - gridRect: Where the grid displays.
    ///   - viewportRect: The visible terminal area.
    ///   - inset: The gap to the grid and the viewport edges.
    /// - Returns: The placement.
    public static func place(
        chipSize: CGSize,
        compactChipSize: CGSize,
        gridRect: CGRect,
        viewportRect: CGRect,
        inset: CGFloat = defaultInset
    ) -> TerminalSizingChipPlacement {
        let grid = gridRect.intersection(viewportRect).isNull ? viewportRect : gridRect.intersection(viewportRect)
        let maxWidth = max(0, viewportRect.width - inset * 2)
        let size = CGSize(width: min(chipSize.width, maxWidth), height: chipSize.height)

        if viewportRect.maxY - grid.maxY >= size.height + inset * 2 {
            let frame = CGRect(
                x: trailingAlignedX(width: size.width, trailing: grid.maxX, in: viewportRect, inset: inset),
                y: grid.maxY + inset,
                width: size.width,
                height: size.height
            )
            return TerminalSizingChipPlacement(frame: frame, anchor: .belowGrid)
        }
        if viewportRect.maxX - grid.maxX >= size.width + inset * 2,
           grid.height >= size.height {
            let frame = CGRect(
                x: grid.maxX + inset,
                y: grid.maxY - size.height,
                width: size.width,
                height: size.height
            )
            return TerminalSizingChipPlacement(frame: frame, anchor: .besideGrid)
        }
        if grid.minY - viewportRect.minY >= size.height + inset * 2 {
            let frame = CGRect(
                x: trailingAlignedX(width: size.width, trailing: grid.maxX, in: viewportRect, inset: inset),
                y: grid.minY - inset - size.height,
                width: size.width,
                height: size.height
            )
            return TerminalSizingChipPlacement(frame: frame, anchor: .aboveGrid)
        }
        let compact = CGSize(width: min(compactChipSize.width, maxWidth), height: compactChipSize.height)
        let frame = CGRect(
            x: viewportRect.maxX - inset - compact.width,
            y: viewportRect.minY + inset,
            width: compact.width,
            height: compact.height
        )
        return TerminalSizingChipPlacement(frame: frame, anchor: .viewportTopTrailing)
    }

    /// The x of a chip whose trailing edge meets `trailing`, kept inside the
    /// viewport.
    private static func trailingAlignedX(
        width: CGFloat,
        trailing: CGFloat,
        in viewport: CGRect,
        inset: CGFloat
    ) -> CGFloat {
        let x = min(trailing, viewport.maxX - inset) - width
        return max(viewport.minX + inset, x)
    }
}
