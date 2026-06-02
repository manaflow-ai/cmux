import Foundation

/// A resolved value carried by render nodes and modifiers. Distinct from
/// `LispValue`: this layer has no functions, symbols, or environments, so it can
/// be compared cheaply and is safe to retain across render passes.
public indirect enum RNValue: Equatable {
    case number(Double)
    case string(String)
    case bool(Bool)
    case color(RNColor)
    case font(RNFont)
    case gradient(RNGradient)
    case alignment(RNAlignment)
    case edges(RNEdges)
    case shadow(RNShadow)
    case action(RNAction)
    case node(RenderNode)
    case list([RNValue])
    case null

    public var number: Double? {
        if case .number(let n) = self { return n }
        return nil
    }
    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

public enum RNColor: Equatable {
    case hex(String)
    case rgba(Double, Double, Double, Double)
    /// A named SwiftUI Color asset or CSS-ish color name.
    case named(String)
    /// A semantic color: "primary", "secondary", "accent", "clear".
    case semantic(String)
}

public struct RNFont: Equatable {
    public var size: Double?
    /// "thin", "light", "regular", "medium", "semibold", "bold", "heavy", "black".
    public var weight: String?
    /// "default", "serif", "rounded", "monospaced".
    public var design: String?
    /// A system text style, e.g. "body", "headline", "caption".
    public var textStyle: String?
    public var italic: Bool
    public var monospacedDigit: Bool

    public init(
        size: Double? = nil,
        weight: String? = nil,
        design: String? = nil,
        textStyle: String? = nil,
        italic: Bool = false,
        monospacedDigit: Bool = false
    ) {
        self.size = size
        self.weight = weight
        self.design = design
        self.textStyle = textStyle
        self.italic = italic
        self.monospacedDigit = monospacedDigit
    }
}

public struct RNGradient: Equatable {
    public enum Direction: String { case vertical, horizontal, diagonal }
    public var colors: [RNColor]
    public var direction: Direction
    public init(colors: [RNColor], direction: Direction) {
        self.colors = colors
        self.direction = direction
    }
}

/// A 2D alignment token: "leading", "center", "trailing", "top", "bottom",
/// "top-leading", "bottom-trailing", etc.
public struct RNAlignment: Equatable {
    public var raw: String
    public init(_ raw: String) { self.raw = raw }
}

/// Edge inset spec (a uniform amount or per-edge).
public struct RNEdges: Equatable {
    public var top: Double
    public var leading: Double
    public var bottom: Double
    public var trailing: Double
    public init(top: Double = 0, leading: Double = 0, bottom: Double = 0, trailing: Double = 0) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }
    public static func uniform(_ v: Double) -> RNEdges {
        RNEdges(top: v, leading: v, bottom: v, trailing: v)
    }
}

public struct RNShadow: Equatable {
    public var color: RNColor
    public var radius: Double
    public var x: Double
    public var y: Double
    public init(color: RNColor, radius: Double, x: Double = 0, y: Double = 0) {
        self.color = color
        self.radius = radius
        self.x = x
        self.y = y
    }
}

/// A side-effect a node can request (a tap target). The host resolves these to
/// real behavior (open a URL, copy text, ...). Equatable so nodes stay
/// comparable; the payload is plain data.
public struct RNAction: Equatable {
    public var kind: String
    public var payload: [String: String]
    public init(kind: String, payload: [String: String] = [:]) {
        self.kind = kind
        self.payload = payload
    }
}
