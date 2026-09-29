public import CoreGraphics

/// How the phone renders the shared PTY grid against its own viewport.
///
/// The host can now publish a grid larger than this phone (Follow latest,
/// Largest window, Priority, Fixed). libghostty must still parse the byte
/// stream at the exact shared grid, or wrapped lines, cursor addressing and
/// full-screen apps garble, and every render-grid replay fails the local grid
/// fence. So the surface always renders the exact grid; only the displayed
/// size changes.
public enum TerminalGridFitMode: Equatable, Sendable {
    /// No shared grid, or the grid equals the phone's natural grid: the
    /// surface fills the container.
    case natural
    /// The grid fits inside the phone: the exact grid renders at 1:1 and the
    /// remaining container area is the letterbox.
    case letterbox
    /// The grid is wider or taller than the phone: the exact grid renders at
    /// its full size and is displayed scaled down to the viewport width
    /// (see ``TerminalScaledGridLayout``).
    case scaledToFit
}

/// Pure decision for ``TerminalGridFitMode``.
public struct TerminalGridFit {
    private init() {}

    /// Chooses how to render the shared grid.
    ///
    /// - Parameters:
    ///   - effectiveColumns: The shared grid's columns, or `nil` without one.
    ///   - effectiveRows: The shared grid's rows, or `nil` without one.
    ///   - measuredColumns: The phone's natural columns at the container size.
    ///   - measuredRows: The phone's natural rows at the container size.
    ///   - gridPointSize: The shared grid's size in points at the live font.
    ///   - container: The drawable container size in points.
    /// - Returns: The render mode.
    public static func mode(
        effectiveColumns: Int?,
        effectiveRows: Int?,
        measuredColumns: Int,
        measuredRows: Int,
        gridPointSize: CGSize,
        container: CGSize
    ) -> TerminalGridFitMode {
        guard let cols = effectiveColumns, let rows = effectiveRows,
              cols > 0, rows > 0, measuredColumns > 0, measuredRows > 0,
              gridPointSize.width > 0, gridPointSize.height > 0 else {
            return .natural
        }
        if cols > measuredColumns || rows > measuredRows {
            return .scaledToFit
        }
        if cols == measuredColumns && rows == measuredRows {
            return .natural
        }
        // The grid fits inside the natural grid. Pin it whenever the pinned
        // box is meaningfully smaller than the container on either axis.
        if gridPointSize.width + 0.5 < container.width || gridPointSize.height + 0.5 < container.height {
            return .letterbox
        }
        return .natural
    }
}

/// Where a grid larger than the phone is displayed.
///
/// At magnification 1 the grid is scaled so its width matches the viewport
/// width (never enlarged past 1:1), keeping aspect. It is left-aligned and
/// bottom-pinned like the letterbox, so the newest rows ride the dock and any
/// vertical slack shows above the grid. A pinch magnifies around the pinch
/// point up to 1:1, and `offset` pans the magnified grid. `offset` is the
/// distance scrolled from the default anchor: `x` from the left edge toward
/// the right, `y` from the bottom edge toward the top. Both are clamped so
/// the grid never leaves an empty gap inside the viewport on an axis it
/// overflows.
public struct TerminalScaledGridLayout: Equatable, Sendable {
    /// The largest display scale: 1:1 with the rendered pixels. Zooming past
    /// it would only blur the text.
    public static let maximumDisplayScale: CGFloat = 1

    /// The grid's rendered size in points (unscaled).
    public let gridSize: CGSize
    /// The visible terminal area.
    public let viewport: CGRect
    /// The scale at which the grid width fits the viewport width.
    public let fitScale: CGFloat
    /// The clamped pinch magnification on top of `fitScale`.
    public let magnification: CGFloat
    /// `fitScale * magnification`.
    public let displayScale: CGFloat
    /// The clamped pan offset.
    public let offset: CGPoint
    /// Where the scaled grid is displayed, in viewport coordinates.
    public let displayRect: CGRect

    /// The largest magnification: the one that reaches 1:1.
    public var maximumMagnification: CGFloat {
        max(1, Self.maximumDisplayScale / fitScale)
    }

    /// Whether the displayed grid is smaller than it renders.
    public var isScaled: Bool {
        displayScale < 1 - 0.0001
    }

    /// Computes the layout.
    /// - Parameters:
    ///   - gridSize: The grid's rendered size in points.
    ///   - viewport: The visible terminal area.
    ///   - magnification: The requested magnification (clamped).
    ///   - offset: The requested pan offset (clamped).
    public init(
        gridSize: CGSize,
        viewport: CGRect,
        magnification: CGFloat = 1,
        offset: CGPoint = .zero
    ) {
        self.gridSize = gridSize
        self.viewport = viewport
        let fit: CGFloat = gridSize.width > 0 && viewport.width > 0
            ? min(Self.maximumDisplayScale, viewport.width / gridSize.width)
            : 1
        fitScale = fit
        let maxMagnification = max(1, Self.maximumDisplayScale / fit)
        let clampedMagnification = magnification.isFinite
            ? min(max(1, magnification), maxMagnification)
            : 1
        self.magnification = clampedMagnification
        let scale = fit * clampedMagnification
        displayScale = scale
        let displayed = CGSize(width: gridSize.width * scale, height: gridSize.height * scale)
        let maxX = max(0, displayed.width - viewport.width)
        let maxY = max(0, displayed.height - viewport.height)
        let clamped = CGPoint(
            x: offset.x.isFinite ? min(max(0, offset.x), maxX) : 0,
            y: offset.y.isFinite ? min(max(0, offset.y), maxY) : 0
        )
        self.offset = clamped
        displayRect = CGRect(
            x: viewport.minX - clamped.x,
            y: viewport.maxY - displayed.height + clamped.y,
            width: displayed.width,
            height: displayed.height
        )
    }

    /// The layout after magnifying to `magnification`, keeping the grid
    /// point under `focus` fixed on screen.
    /// - Parameters:
    ///   - magnification: The requested magnification (clamped).
    ///   - focus: The pinch point in viewport coordinates.
    public func zoomed(to magnification: CGFloat, about focus: CGPoint) -> TerminalScaledGridLayout {
        guard displayScale > 0 else { return self }
        let gridX = (focus.x - displayRect.minX) / displayScale
        let gridY = (focus.y - displayRect.minY) / displayScale
        let scaled = TerminalScaledGridLayout(gridSize: gridSize, viewport: viewport, magnification: magnification)
        let scale = scaled.displayScale
        let minX = focus.x - gridX * scale
        let minY = focus.y - gridY * scale
        let height = gridSize.height * scale
        return TerminalScaledGridLayout(
            gridSize: gridSize,
            viewport: viewport,
            magnification: scaled.magnification,
            offset: CGPoint(x: viewport.minX - minX, y: minY - (viewport.maxY - height))
        )
    }

    /// The layout after the fingers moved by `translation` points.
    /// - Parameter translation: The finger movement in viewport coordinates.
    public func panned(by translation: CGPoint) -> TerminalScaledGridLayout {
        TerminalScaledGridLayout(
            gridSize: gridSize,
            viewport: viewport,
            magnification: magnification,
            offset: CGPoint(x: offset.x - translation.x, y: offset.y + translation.y)
        )
    }
}
