import Foundation

/// A `window-padding-x` or `window-padding-y` value: one size for both sides
/// (`2`), or a leading and trailing pair (`4,8`, left/right or top/bottom).
public struct GhosttyWindowPadding: Equatable, Sendable {
    /// Left (for x) or top (for y) padding, in points.
    public var leading: Int
    /// Right (for x) or bottom (for y) padding, in points, when it differs from
    /// ``leading``; `nil` when the value is a single size.
    public var trailing: Int?

    public init(leading: Int, trailing: Int? = nil) {
        self.leading = leading
        self.trailing = trailing
    }

    /// Parses Ghostty's `a` or `a,b` spelling.
    public init?(configValue: String) {
        let sides = configValue.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard (1...2).contains(sides.count),
              let leading = Int(sides[0]), leading >= 0 else {
            return nil
        }
        var trailing: Int?
        if sides.count == 2 {
            guard let parsed = Int(sides[1]), parsed >= 0 else { return nil }
            trailing = parsed
        }
        self.init(leading: leading, trailing: trailing)
    }

    /// The padding with a new leading side, keeping a distinct trailing side.
    public func withLeading(_ points: Int) -> GhosttyWindowPadding {
        GhosttyWindowPadding(leading: max(points, 0), trailing: trailing)
    }

    /// Ghostty's spelling: `a`, or `a,b` when the trailing side is set.
    public var configValue: String {
        guard let trailing else { return String(leading) }
        return "\(leading),\(trailing)"
    }
}
