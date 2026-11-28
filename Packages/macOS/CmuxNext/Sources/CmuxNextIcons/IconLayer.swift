public import CoreGraphics

/// One drawing step of an icon, in grid units (scripts/icons/build_pack.py).
/// Clear operations erase what earlier layers drew.
public nonisolated struct IconLayer: Hashable, Sendable, Decodable {
    public nonisolated enum Operation: String, Hashable, Sendable, Decodable {
        case stroke
        case fill
        case clearFill
        case clearStroke

        public var strokes: Bool { self == .stroke || self == .clearStroke }
        public var clears: Bool { self == .clearFill || self == .clearStroke }
    }

    public nonisolated enum Cap: String, Hashable, Sendable, Decodable {
        case butt
        case round
        case square

        public var cgLineCap: CGLineCap {
            switch self {
            case .butt: .butt
            case .round: .round
            case .square: .square
            }
        }
    }

    public nonisolated enum Join: String, Hashable, Sendable, Decodable {
        case miter
        case round
        case bevel

        public var cgLineJoin: CGLineJoin {
            switch self {
            case .miter: .miter
            case .round: .round
            case .bevel: .bevel
            }
        }
    }

    /// Path data: absolute M, L, C and Z only (`CGPath.icon`).
    public var d: String
    public var op: Operation
    public var width: CGFloat
    public var alpha: CGFloat
    public var dash: [CGFloat]
    public var dashPhase: CGFloat
    public var cap: Cap
    public var join: Join
    /// Drawn in the accent color instead of the ink color.
    public var accent: Bool

    public init(
        d: String,
        op: Operation,
        width: CGFloat = 1.5,
        alpha: CGFloat = 1,
        dash: [CGFloat] = [],
        dashPhase: CGFloat = 0,
        cap: Cap = .round,
        join: Join = .round,
        accent: Bool = false
    ) {
        self.d = d
        self.op = op
        self.width = width
        self.alpha = alpha
        self.dash = dash
        self.dashPhase = dashPhase
        self.cap = cap
        self.join = join
        self.accent = accent
    }

    private enum CodingKeys: String, CodingKey {
        case d, op, w, alpha, dash, dashPhase, cap, join, accent
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            d: try container.decode(String.self, forKey: .d),
            op: try container.decode(Operation.self, forKey: .op),
            width: try container.decodeIfPresent(CGFloat.self, forKey: .w) ?? 1.5,
            alpha: try container.decodeIfPresent(CGFloat.self, forKey: .alpha) ?? 1,
            dash: try container.decodeIfPresent([CGFloat].self, forKey: .dash) ?? [],
            dashPhase: try container.decodeIfPresent(CGFloat.self, forKey: .dashPhase) ?? 0,
            cap: try container.decodeIfPresent(Cap.self, forKey: .cap) ?? .round,
            join: try container.decodeIfPresent(Join.self, forKey: .join) ?? .round,
            accent: try container.decodeIfPresent(Bool.self, forKey: .accent) ?? false
        )
    }
}
