#if os(iOS)
import SwiftUI
import UIKit

/// Which rows have their swipe actions open, across every list, so the team
/// drawer can follow Mail and Messages: while a row's actions are open, a
/// rightward swipe closes them and never opens the drawer (SPEC swipe rules).
///
/// `List` rows (`.swipeActions`) are found in the view tree
/// (``hasOpenListRow(in:)``); rows drawn outside `List` (the Feed) report
/// here while open, with a way to close them.
@MainActor
public final class RowSwipeActions {
    public static let shared = RowSwipeActions()

    /// Open rows outside `List`, by owner, each with its close action.
    private var closers: [String: () -> Void] = [:]

    public init() {}

    /// Rows outside `List` with open actions.
    public var hasOpenRow: Bool { !closers.isEmpty }

    /// `owner`'s row opened (`close` puts it back) or closed (nil).
    public func setOpen(_ owner: String, close: (() -> Void)?) {
        closers[owner] = close
    }

    /// Closes every open row outside `List`.
    public func closeAll() {
        let open = closers
        closers = [:]
        for close in open.values { close() }
    }

    /// The pan recognizers of rows outside `List` carry this name, so the
    /// drawer's pan waits for a row's pan to fail first: a row whose actions
    /// are open takes the rightward swipe to close them.
    public static let panName = "cmux.rowSwipeActions"

    /// Whether a visible `List` (table or collection view) under `root` has
    /// a row slid open on its swipe actions: a cell away from its laid-out place.
    /// A vertical list's cells are not walked (no list of rows lives inside a
    /// row): the walk runs on every touch-down that could open the drawer, and a
    /// list's cells hold most of the screen's views.
    public static func hasOpenListRow(in root: UIView) -> Bool {
        guard !root.isHidden, root.alpha > 0.01, root.window != nil else { return false }
        if let collection = root as? UICollectionView {
            if hasOpenRow(collection) { return true }
            if isVerticalList(collection) { return false }
        }
        if let table = root as? UITableView { return hasOpenRow(table) }
        return root.subviews.contains { hasOpenListRow(in: $0) }
    }

    /// No sideways scrolling: a List, not a grid row, pager or carousel.
    private static func isVerticalList(_ collection: UICollectionView) -> Bool {
        collection.bounds.width > 1 && collection.contentSize.width <= collection.bounds.width + 1
    }

    /// A list's cells share one leading edge; the open row's cell is slid
    /// off it (its layout attributes slide with it, so they cannot tell).
    /// Only a vertical list counts: no sideways scrolling, and rows (cells
    /// nearly as wide as the list). A grid, a pager or a carousel has cells
    /// at different edges by design.
    private static func hasOpenRow(_ collection: UICollectionView) -> Bool {
        let width = collection.bounds.width
        guard width > 1, collection.contentSize.width <= width + 1 else { return false }
        let cells = collection.visibleCells.filter { !$0.isHidden && $0.bounds.width > 1 }
        guard !cells.isEmpty, cells.allSatisfy({ $0.bounds.width >= width * 0.8 }) else { return false }
        return hasSlidCell(cells.map(\.frame.minX))
    }

    /// Whether any of these leading edges is off the one most cells share,
    /// or left of the list's content (a lone open row).
    static func hasSlidCell(_ edges: [CGFloat]) -> Bool {
        guard let first = edges.first else { return false }
        if edges.contains(where: { $0 < -0.5 }) { return true }
        var counts: [CGFloat: Int] = [:]
        for edge in edges { counts[(edge * 2).rounded() / 2, default: 0] += 1 }
        let shared = counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? first
        return edges.contains { abs($0 - shared) > 0.5 }
    }

    private static func hasOpenRow(_ table: UITableView) -> Bool {
        for path in table.indexPathsForVisibleRows ?? [] {
            guard let cell = table.cellForRow(at: path) else { continue }
            if isSlid(cell, from: table.rectForRow(at: path)) { return true }
        }
        return false
    }

    /// UIKit slides an open row's cell off its laid-out place, over the
    /// actions (measured on iOS 26.5: a List cell at x = -242 with three
    /// actions). The actions' own view stays in the hierarchy at full width
    /// after the row closes, so it says nothing about open rows.
    private static func isSlid(_ cell: UIView, from laidOut: CGRect) -> Bool {
        if cell.frame.minX < laidOut.minX - 0.5 { return true }
        // Only leftward: editing mode moves a table cell's content to the right.
        guard let content = (cell as? UITableViewCell)?.contentView else { return false }
        return content.frame.minX < -0.5 || content.transform.tx < -0.5
    }
}

/// The iOS 26 swipe action button that `List`'s `.swipeActions` draws
/// (Workspaces, Home): a tinted capsule with a white symbol, its title
/// under it, inset from the row's edge. Rows outside `List` (the Feed) draw
/// theirs with ``RowSwipeActionButton`` so every list's actions look alike.
/// Measured on the iOS 26.5 simulator (Home's row: 66 x 50 pt capsules
/// 12 pt apart, 10 pt from the trailing edge, the title 7 pt below).
public struct RowSwipeActionStyle: Equatable, Sendable {
    public var buttonWidth: CGFloat = 66
    public var buttonHeight: CGFloat = 50
    public var spacing: CGFloat = 12
    public var trailingInset: CGFloat = 10
    public var titleGap: CGFloat = 7

    public init() {}

    public static let standard = RowSwipeActionStyle()

    /// How far a row slides to show `count` buttons (with a gap before the first).
    public func revealWidth(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * buttonWidth + CGFloat(count) * spacing + trailingInset
    }

    /// Each button's width while `revealed` points of the row are uncovered:
    /// they grow together up to `buttonWidth` (as `List`'s do mid-swipe).
    public func buttonWidth(revealed: CGFloat, count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let room = revealed - trailingInset - CGFloat(count) * spacing
        return min(buttonWidth, max(0, room / CGFloat(count)))
    }

    /// The outermost button's width once a full swipe is armed: all the room.
    public func fullSwipeWidth(revealed: CGFloat) -> CGFloat {
        max(0, revealed - trailingInset - spacing)
    }
}

/// One swipe action button (``RowSwipeActionStyle``). Narrower than the
/// style's width mid-swipe, it shrinks to a circle and hides its title.
public struct RowSwipeActionButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let width: CGFloat
    let style: RowSwipeActionStyle
    /// The row's height: a row too short for the capsule and its title
    /// (under 80 pt) shows the capsule alone, inset 8 pt top and bottom.
    let maxHeight: CGFloat
    let action: () -> Void

    public init(title: String, systemImage: String, tint: Color, width: CGFloat, maxHeight: CGFloat = .infinity,
                style: RowSwipeActionStyle = .standard, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.width = width
        self.maxHeight = maxHeight
        self.style = style
        self.action = action
    }

    public var body: some View {
        let showsTitle = maxHeight >= 80
        let height = min(style.buttonHeight, width, showsTitle ? .infinity : max(0, maxHeight - 16))
        let shown = style.buttonWidth > 0 ? min(1, width / style.buttonWidth) : 1
        Button(action: action) {
            VStack(spacing: style.titleGap) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.white)
                    .frame(width: width, height: height)
                    .background(tint, in: .capsule)
                    .opacity(width < 1 ? 0 : 1)
                if showsTitle {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(width: max(width, 1))
                        .opacity(shown > 0.8 ? 1 : 0)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
#endif
