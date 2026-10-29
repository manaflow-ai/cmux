public import Foundation
public import CoreGraphics

/// A path as plain geometry, built with the `CGMutablePath` calls it mirrors. Design tokens (the
/// launch mark, the status glyphs) describe their shapes with it as plain values that tests can
/// compare; ``cgPath`` replays the elements, call for call, into the `CGPath` layers and contexts draw.
/// Chromium splits it the same way: portable geometry in `ui/gfx/geometry/` and `SkPath`, converted
/// to the platform's types only where AppKit draws (`ui/gfx/path_mac.mm`, `ui/gfx/mac/coordinate_conversion.mm`).
public nonisolated struct OutlinePath: Sendable, Equatable {
    /// One `CGMutablePath` call.
    public enum Element: Sendable, Equatable {
        case move(to: CGPoint)
        case line(to: CGPoint)
        /// `addArc(center:radius:startAngle:endAngle:clockwise:)`, angles in radians.
        case arc(center: CGPoint, radius: CGFloat, startAngle: CGFloat, endAngle: CGFloat, clockwise: Bool)
        case ellipse(in: CGRect)
        case roundedRect(in: CGRect, cornerWidth: CGFloat, cornerHeight: CGFloat)
        case close
    }

    /// The calls in order.
    public private(set) var elements: [Element]

    /// An empty path.
    public init() {
        elements = []
    }

    /// Starts a subpath at `point`.
    public mutating func move(to point: CGPoint) {
        elements.append(.move(to: point))
    }

    /// A straight line from the current point to `point`.
    public mutating func addLine(to point: CGPoint) {
        elements.append(.line(to: point))
    }

    /// A subpath through `points`: a move to the first, then a line to each next one.
    public mutating func addLines(between points: [CGPoint]) {
        guard let first = points.first else { return }
        move(to: first)
        for point in points.dropFirst() { addLine(to: point) }
    }

    /// An arc of the circle at `center`, angles in radians; `clockwise` as `CGMutablePath` takes it.
    public mutating func addArc(center: CGPoint, radius: CGFloat, startAngle: CGFloat, endAngle: CGFloat, clockwise: Bool) {
        elements.append(.arc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: clockwise))
    }

    /// The ellipse inscribed in `rect`, as its own closed subpath.
    public mutating func addEllipse(in rect: CGRect) {
        elements.append(.ellipse(in: rect))
    }

    /// `rect` with rounded corners, as its own closed subpath. Each corner size is at most half the side.
    public mutating func addRoundedRect(in rect: CGRect, cornerWidth: CGFloat, cornerHeight: CGFloat) {
        elements.append(.roundedRect(in: rect, cornerWidth: cornerWidth, cornerHeight: cornerHeight))
    }

    /// Closes the current subpath with a line back to its start.
    public mutating func closeSubpath() {
        elements.append(.close)
    }
}

/// One window the window server lists, in global screen coordinates with the origin at the top
/// left of the main display (`CGWindowListCopyWindowInfo`'s space).
public nonisolated struct ListedWindow: Sendable, Equatable {
    public var bounds: CGRect
    public var alpha: Double
    public var owner: String
    /// The window server's number for it, 0 when unknown.
    public var number: Int
    /// Its window layer; 0 is a normal app window.
    public var layer: Int

    public init(bounds: CGRect, alpha: Double = 1, owner: String = "", number: Int = 0, layer: Int = 0) {
        self.bounds = bounds
        self.alpha = alpha
        self.owner = owner
        self.number = number
        self.layer = layer
    }
}

/// The window server's list of on-screen windows.
public nonisolated struct WindowServerList: Sendable {
    public init() {}
}

extension OutlinePath {
    /// The path as CoreGraphics draws it: each element replayed into a `CGMutablePath`.
    public var cgPath: CGPath {
        let path = CGMutablePath()
        for element in elements {
            switch element {
            case .move(let point): path.move(to: point)
            case .line(let point): path.addLine(to: point)
            case .arc(let center, let radius, let startAngle, let endAngle, let clockwise):
                path.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: clockwise)
            case .ellipse(let rect): path.addEllipse(in: rect)
            case .roundedRect(let rect, let cornerWidth, let cornerHeight):
                path.addRoundedRect(in: rect, cornerWidth: cornerWidth, cornerHeight: cornerHeight)
            case .close: path.closeSubpath()
            }
        }
        return path
    }
}

extension WindowServerList {
    /// The on-screen windows above window `number`, desktop elements left out. It waits for the
    /// window server: call it on a system lane, never on the main thread.
    public nonisolated func windows(above number: Int) -> [ListedWindow] {
        guard number > 0,
              let list = blockingWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .excludeDesktopElements], CGWindowID(number)) as? [[String: Any]]
        else { return [] }
        return list.compactMap { info in
            guard let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) })
            else { return nil }
            return ListedWindow(bounds: bounds, alpha: info[kCGWindowAlpha as String] as? Double ?? 1,
                                owner: info[kCGWindowOwnerName as String] as? String ?? "",
                                number: info[kCGWindowNumber as String] as? Int ?? 0, layer: info[kCGWindowLayer as String] as? Int ?? 0)
        }
    }
}
