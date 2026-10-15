public import CoreGraphics
import Foundation

/// Where docked developer tools sit inside a browser pane's content area, and the page's share.
///
/// Pure geometry in the content view's coordinates, which are not flipped: y grows upward, so
/// the bottom dock starts at `bounds.minY`. Ported from cmux Next's Chromium DevTools layout so
/// both apps resize and dock the same way.
///
/// ```swift
/// var layout = BrowserDevToolsLayout(dock: .right)
/// let frames = layout.frames(in: pane.bounds, devToolsDocked: true)
/// layout.dragDivider(to: mouse, in: pane.bounds)  // the user drags the line
/// ```
public struct BrowserDevToolsLayout: Hashable, Sendable {
    /// The dock side the tools use (and open on next).
    public var dock: BrowserDevToolsDock
    /// Tools height as a share of the content height, for the bottom dock.
    public var bottomFraction: Double
    /// Tools width as a share of the content width, for the left and right docks.
    public var sideFraction: Double
    /// Thickness of the divider line between page and tools: the pane divider thickness setting
    /// (``resolvedLineThickness(_:)``), so it matches the pane dividers next to it.
    public var lineThickness: CGFloat = Self.defaultLineThickness

    /// The divider line's thickness before the app passes its pane divider setting.
    public static let defaultLineThickness: CGFloat = 1
    /// The thickest divider line (the pane divider setting's range is 0 to 12).
    public static let maximumLineThickness: CGFloat = 12

    /// The line thickness for a pane divider thickness setting: clamped to 1...12 points, and
    /// 1 point at 0 so the edge stays findable.
    /// - Parameter value: The pane divider thickness setting.
    /// - Returns: The divider line thickness.
    public static func resolvedLineThickness(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return defaultLineThickness }
        return min(max(value, 1), maximumLineThickness)
    }
    /// How far past the line, into the page and the tools, the divider still takes the mouse.
    public static let grabOutset: CGFloat = 3
    /// The smallest tools extent kept while the pane is large enough.
    public static let minimumDevToolsExtent: CGFloat = 120
    /// The smallest page extent kept while the pane is large enough.
    public static let minimumPageExtent: CGFloat = 80
    /// The range a stored fraction must fall in to be trusted.
    public static let validFractions: ClosedRange<Double> = 0.05...0.95

    /// Creates a layout.
    /// - Parameters:
    ///   - dock: The dock side. Defaults to ``BrowserDevToolsDock/bottom``, Classic's attached
    ///     inspector position.
    ///   - bottomFraction: Tools share of the height when docked at the bottom. Defaults to 0.4.
    ///   - sideFraction: Tools share of the width when docked at a side. Defaults to 0.45.
    public init(dock: BrowserDevToolsDock = .bottom, bottomFraction: Double = 0.4, sideFraction: Double = 0.45) {
        self.dock = dock
        self.bottomFraction = bottomFraction
        self.sideFraction = sideFraction
    }

    /// Frames for content `bounds`. With the tools closed or in their own window the page fills
    /// the bounds and every other frame is `.zero`.
    /// - Parameters:
    ///   - bounds: The pane's content bounds.
    ///   - devToolsDocked: Whether docked tools take room now (open, or opening).
    /// - Returns: The page, tools, line and grab frames.
    public func frames(in bounds: CGRect, devToolsDocked: Bool) -> BrowserDevToolsLayoutFrames {
        guard devToolsDocked, dock.isDocked else {
            return BrowserDevToolsLayoutFrames(page: bounds, devTools: .zero, line: .zero, grab: .zero)
        }
        let line = lineThickness
        let outset = Self.grabOutset
        switch dock {
        case .right:
            let size = Self.devToolsExtent(fraction: sideFraction, extent: bounds.width, lineThickness: line)
            let devTools = CGRect(x: bounds.maxX - size, y: bounds.minY, width: size, height: bounds.height)
            let lineRect = CGRect(x: devTools.minX - line, y: bounds.minY, width: line, height: bounds.height)
            let page = CGRect(x: bounds.minX, y: bounds.minY, width: max(lineRect.minX - bounds.minX, 0), height: bounds.height)
            return BrowserDevToolsLayoutFrames(page: page, devTools: devTools, line: lineRect, grab: lineRect.insetBy(dx: -outset, dy: 0))
        case .left:
            let size = Self.devToolsExtent(fraction: sideFraction, extent: bounds.width, lineThickness: line)
            let devTools = CGRect(x: bounds.minX, y: bounds.minY, width: size, height: bounds.height)
            let lineRect = CGRect(x: devTools.maxX, y: bounds.minY, width: line, height: bounds.height)
            let page = CGRect(x: lineRect.maxX, y: bounds.minY, width: max(bounds.maxX - lineRect.maxX, 0), height: bounds.height)
            return BrowserDevToolsLayoutFrames(page: page, devTools: devTools, line: lineRect, grab: lineRect.insetBy(dx: -outset, dy: 0))
        case .bottom, .window:
            let size = Self.devToolsExtent(fraction: bottomFraction, extent: bounds.height, lineThickness: line)
            let devTools = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: size)
            let lineRect = CGRect(x: bounds.minX, y: devTools.maxY, width: bounds.width, height: line)
            let page = CGRect(x: bounds.minX, y: lineRect.maxY, width: bounds.width, height: max(bounds.maxY - lineRect.maxY, 0))
            return BrowserDevToolsLayoutFrames(page: page, devTools: devTools, line: lineRect, grab: lineRect.insetBy(dx: 0, dy: -outset))
        }
    }

    /// The tools extent along the dock axis: `fraction` of the available extent, kept between the
    /// tools and page minimums when the pane is large enough, and split evenly when it is not.
    /// - Parameters:
    ///   - fraction: The wanted share of the available extent.
    ///   - extent: The pane's extent along the dock axis.
    ///   - lineThickness: The divider line's thickness. Defaults to ``defaultLineThickness``.
    /// - Returns: The tools extent in points, rounded to whole points.
    public static func devToolsExtent(fraction: Double, extent: CGFloat, lineThickness: CGFloat = defaultLineThickness) -> CGFloat {
        let available = max(extent - lineThickness, 0)
        let wanted = (available * CGFloat(fraction)).rounded()
        guard available >= minimumDevToolsExtent + minimumPageExtent else { return (available * 0.5).rounded() }
        return min(max(wanted, minimumDevToolsExtent), available - minimumPageExtent)
    }

    /// The tools' share of the pane along the dock axis, 0 to 1 (the divider's accessibility value).
    public var devToolsShare: Double {
        dock.isSide ? sideFraction : bottomFraction
    }

    /// Grows the tools by `points` along the dock axis (negative shrinks them), within the
    /// tools and page minimums: the divider's arrow keys and accessibility increment.
    /// - Parameters:
    ///   - points: The change of the tools' extent.
    ///   - bounds: The pane's content bounds.
    public mutating func resizeDevTools(by points: CGFloat, in bounds: CGRect) {
        let extent = dock.isSide ? bounds.width : bounds.height
        let available = max(extent - lineThickness, 1)
        let current = Self.devToolsExtent(fraction: devToolsShare, extent: extent, lineThickness: lineThickness)
        let size = Self.devToolsExtent(fraction: Double((current + points) / available), extent: extent, lineThickness: lineThickness)
        if dock.isSide {
            sideFraction = Double(size / available)
        } else {
            bottomFraction = Double(size / available)
        }
    }

    /// Moves the divider line to `point` during a drag, updating the fraction of the current dock.
    /// - Parameters:
    ///   - point: The mouse location in content coordinates.
    ///   - bounds: The pane's content bounds.
    public mutating func dragDivider(to point: CGPoint, in bounds: CGRect) {
        switch dock {
        case .right:
            let available = max(bounds.width - lineThickness, 1)
            let size = Self.devToolsExtent(fraction: Double((bounds.maxX - point.x) / available), extent: bounds.width, lineThickness: lineThickness)
            sideFraction = Double(size / available)
        case .left:
            let available = max(bounds.width - lineThickness, 1)
            let size = Self.devToolsExtent(fraction: Double((point.x - bounds.minX) / available), extent: bounds.width, lineThickness: lineThickness)
            sideFraction = Double(size / available)
        case .bottom, .window:
            let available = max(bounds.height - lineThickness, 1)
            let size = Self.devToolsExtent(fraction: Double((point.y - bounds.minY) / available), extent: bounds.height, lineThickness: lineThickness)
            bottomFraction = Double(size / available)
        }
    }
}
