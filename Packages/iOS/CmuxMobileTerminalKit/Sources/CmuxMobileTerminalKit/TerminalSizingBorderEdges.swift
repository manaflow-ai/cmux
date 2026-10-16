public import CoreGraphics

/// The sides of the shared grid's visible rect that get a border line.
///
/// A side is drawn only where the grid meets unused (hatched) space inside
/// the viewport. A side flush with the viewport edge is left open, because
/// the chrome beyond it (the navigation bar, the screen edge, the keyboard)
/// already bounds it.
public struct TerminalSizingBorderEdges: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let top = Self(rawValue: 1 << 0)
    public static let trailing = Self(rawValue: 1 << 1)
    public static let bottom = Self(rawValue: 1 << 2)
    public static let leading = Self(rawValue: 1 << 3)

    /// The sides of `rect` that sit inside `viewport` with space beyond them.
    /// A side within `tolerance` of the viewport edge (or past it) is flush:
    /// the viewport's own edge (a tab bar, navigation bar or divider) already
    /// bounds it, so a line there would double that edge.
    public init(rect: CGRect, in viewport: CGRect, tolerance: CGFloat = 1) {
        self = []
        guard !rect.isEmpty, !viewport.isEmpty else { return }
        if rect.minY - viewport.minY > tolerance { insert(.top) }
        if viewport.maxX - rect.maxX > tolerance { insert(.trailing) }
        if viewport.maxY - rect.maxY > tolerance { insert(.bottom) }
        if rect.minX - viewport.minX > tolerance { insert(.leading) }
    }

    /// Open polylines tracing these sides of `rect` clockwise (top, trailing,
    /// bottom, leading in a top-left origin). Adjacent sides join into one
    /// polyline so their shared corner is a clean join; all four sides close
    /// the loop.
    public func polylines(around rect: CGRect) -> [[CGPoint]] {
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY),
        ]
        let sides: [Self] = [.top, .trailing, .bottom, .leading]
        guard !isEmpty else { return [] }
        if isSuperset(of: [.top, .trailing, .bottom, .leading]) {
            return [corners + [corners[0]]]
        }
        // Start each run at a drawn side whose predecessor is undrawn, so no
        // run is split where the loop wraps.
        let start = (0..<4).first { contains(sides[$0]) && !contains(sides[($0 + 3) % 4]) } ?? 0
        var lines: [[CGPoint]] = []
        var current: [CGPoint] = []
        for offset in 0..<4 {
            let index = (start + offset) % 4
            if contains(sides[index]) {
                if current.isEmpty { current.append(corners[index]) }
                current.append(corners[(index + 1) % 4])
            } else if !current.isEmpty {
                lines.append(current)
                current = []
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }
}
