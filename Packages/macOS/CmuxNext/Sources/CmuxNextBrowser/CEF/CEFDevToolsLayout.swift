import CoreGraphics
import Foundation

/// Where a docked DevTools sits in a CEF tab's content view, and the
/// page's share of it. Pure geometry in the content view's coordinates
/// (not flipped: y grows upward, so "bottom" is y = 0). The last dock side
/// and sizes are remembered for the next DevTools.
nonisolated struct CEFDevToolsLayout: Hashable, Sendable {
    var dock: BrowserDevToolsDock = .bottom
    /// DevTools height as a share of the content height (bottom dock).
    var bottomFraction: Double = 0.4
    /// DevTools width as a share of the content width (left and right dock).
    var rightFraction: Double = 0.45

    /// The drawn divider line between page and DevTools.
    static let lineThickness: CGFloat = 1
    /// How far past the line, into page and DevTools, the divider still
    /// takes the mouse.
    static let grabOutset: CGFloat = 3
    static let minDevTools: CGFloat = 120
    static let minPage: CGFloat = 80

    struct Frames: Hashable, Sendable {
        var page: CGRect
        /// Zero when DevTools is not docked in the content view.
        var devTools: CGRect
        /// The drawn line.
        var line: CGRect
        /// The line plus `grabOutset` on each side (the divider's frame).
        var grab: CGRect
    }

    /// Frames for `bounds`. With DevTools closed or in its own window the
    /// page fills the bounds.
    func frames(in bounds: CGRect, devToolsDocked: Bool) -> Frames {
        guard devToolsDocked, dock.isDocked else {
            return Frames(page: bounds, devTools: .zero, line: .zero, grab: .zero)
        }
        let line = Self.lineThickness
        let outset = Self.grabOutset
        switch dock {
        case .right:
            let size = Self.devToolsExtent(fraction: rightFraction, extent: bounds.width)
            let devTools = CGRect(x: bounds.maxX - size, y: bounds.minY, width: size, height: bounds.height)
            let lineRect = CGRect(x: devTools.minX - line, y: bounds.minY, width: line, height: bounds.height)
            let page = CGRect(x: bounds.minX, y: bounds.minY, width: max(lineRect.minX - bounds.minX, 0), height: bounds.height)
            return Frames(page: page, devTools: devTools, line: lineRect, grab: lineRect.insetBy(dx: -outset, dy: 0))
        case .left:
            let size = Self.devToolsExtent(fraction: rightFraction, extent: bounds.width)
            let devTools = CGRect(x: bounds.minX, y: bounds.minY, width: size, height: bounds.height)
            let lineRect = CGRect(x: devTools.maxX, y: bounds.minY, width: line, height: bounds.height)
            let page = CGRect(x: lineRect.maxX, y: bounds.minY, width: max(bounds.maxX - lineRect.maxX, 0), height: bounds.height)
            return Frames(page: page, devTools: devTools, line: lineRect, grab: lineRect.insetBy(dx: -outset, dy: 0))
        case .bottom, .window:
            let size = Self.devToolsExtent(fraction: bottomFraction, extent: bounds.height)
            let devTools = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: size)
            let lineRect = CGRect(x: bounds.minX, y: devTools.maxY, width: bounds.width, height: line)
            let page = CGRect(x: bounds.minX, y: lineRect.maxY, width: bounds.width, height: max(bounds.maxY - lineRect.maxY, 0))
            return Frames(page: page, devTools: devTools, line: lineRect, grab: lineRect.insetBy(dx: 0, dy: -outset))
        }
    }

    /// DevTools size along the dock axis: the fraction of `extent`, kept
    /// between the DevTools and page minimums when the pane is big enough.
    static func devToolsExtent(fraction: Double, extent: CGFloat) -> CGFloat {
        let available = max(extent - lineThickness, 0)
        let wanted = (available * CGFloat(fraction)).rounded()
        guard available >= minDevTools + minPage else { return (available * 0.5).rounded() }
        return min(max(wanted, minDevTools), available - minPage)
    }

    /// Moves the divider line to `point` (a drag), updating the fraction of
    /// the current dock side.
    mutating func dragDivider(to point: CGPoint, in bounds: CGRect) {
        switch dock {
        case .right:
            let available = max(bounds.width - Self.lineThickness, 1)
            let size = Self.devToolsExtent(fraction: Double((bounds.maxX - point.x) / available), extent: bounds.width)
            rightFraction = Double(size / available)
        case .left:
            let available = max(bounds.width - Self.lineThickness, 1)
            let size = Self.devToolsExtent(fraction: Double((point.x - bounds.minX) / available), extent: bounds.width)
            rightFraction = Double(size / available)
        case .bottom, .window:
            let available = max(bounds.height - Self.lineThickness, 1)
            let size = Self.devToolsExtent(fraction: Double((point.y - bounds.minY) / available), extent: bounds.height)
            bottomFraction = Double(size / available)
        }
    }
}

extension CEFDevToolsLayout {
    private static let defaultsKey = "CmuxNextBrowser.devToolsLayout"

    /// The layout the next DevTools starts with (last used, per process
    /// user defaults).
    @MainActor static var remembered: CEFDevToolsLayout = load(from: .standard)

    @MainActor static func remember(_ layout: CEFDevToolsLayout) {
        remembered = layout
        UserDefaults.standard.set([
            "dock": layout.dock.rawValue, "bottom": layout.bottomFraction, "right": layout.rightFraction,
        ], forKey: defaultsKey)
    }

    static func load(from defaults: UserDefaults) -> CEFDevToolsLayout {
        var layout = CEFDevToolsLayout()
        guard let stored = defaults.dictionary(forKey: defaultsKey) else { return layout }
        if let dock = (stored["dock"] as? String).flatMap(BrowserDevToolsDock.init(rawValue:)) { layout.dock = dock }
        if let bottom = stored["bottom"] as? Double, (0.05...0.95).contains(bottom) { layout.bottomFraction = bottom }
        if let right = stored["right"] as? Double, (0.05...0.95).contains(right) { layout.rightFraction = right }
        return layout
    }
}
