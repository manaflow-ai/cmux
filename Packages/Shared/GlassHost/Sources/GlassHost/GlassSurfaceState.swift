public import CoreGraphics
public import Foundation

/// How dense a glass surface is, from the page's `level`: a popover (cards, pickers, panels), a menu,
/// or a chip (tooltips and small floating controls).
public enum GlassLevel: String, CaseIterable, Sendable {
    case popover
    case menu
    case chip
}

/// One glass surface the page asked for: its box in the page's viewport (CSS pixels, top-left origin),
/// its corner radius (CSS pixels) and its opacity (a fade the page runs).
public struct GlassSurfaceState: Equatable, Sendable {
    public var id: String
    public var level: GlassLevel
    public var rect: CGRect
    public var radius: CGFloat
    public var opacity: CGFloat

    public init(id: String, level: GlassLevel = .popover, rect: CGRect, radius: CGFloat = 0, opacity: CGFloat = 1) {
        self.id = id
        self.level = level
        self.rect = rect
        self.radius = radius
        self.opacity = opacity
    }

    /// The most surfaces one message may carry.
    public static let maximum = 16
    /// The longest surface id.
    public static let idMaximum = 64

    /// Decodes the page's message: the `surfaces` array the web half sends (`[{id, level, left, top,
    /// right, bottom, radius?, opacity?}]`), as a bridge hands it over (a `WKScriptMessage` body, a
    /// decoded JSON object). Nil for anything else: a missing or non-finite number, an inverted box,
    /// an unknown level, a repeated or over-long id, an opacity outside 0...1, or too many surfaces.
    /// The whole message is refused, never part of it.
    public static func decode(_ value: Any?) -> [GlassSurfaceState]? {
        guard let list = value as? [Any], list.count <= maximum else { return nil }
        var surfaces: [GlassSurfaceState] = []
        var ids = Set<String>()
        for item in list {
            guard let box = item as? [String: Any],
                  let id = box["id"] as? String, !id.isEmpty, id.count <= idMaximum, ids.insert(id).inserted,
                  let name = box["level"] as? String, let level = GlassLevel(rawValue: name)
            else { return nil }
            func number(_ key: String) -> Double? {
                guard let value = (box[key] as? NSNumber)?.doubleValue, value.isFinite, abs(value) <= 100_000 else {
                    return nil
                }
                return value
            }
            guard let left = number("left"), let top = number("top"), let right = number("right"),
                  let bottom = number("bottom"), right >= left, bottom >= top else { return nil }
            let radius = box["radius"] == nil ? 0 : number("radius")
            let opacity = box["opacity"] == nil ? 1 : number("opacity")
            guard let radius, radius >= 0, let opacity, (0...1).contains(opacity) else { return nil }
            surfaces.append(GlassSurfaceState(
                id: id, level: level,
                rect: CGRect(x: left, y: top, width: right - left, height: bottom - top),
                radius: CGFloat(radius), opacity: CGFloat(opacity)
            ))
        }
        return surfaces
    }
}
