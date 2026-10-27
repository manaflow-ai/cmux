public import Foundation

/// One density: the single token set that sizes chrome (rows, tabs, insets, radii, icons and
/// text) together (plans/cmux-next/density-DESIGN.md).
///
/// A density sits on the compact→comfortable axis at `level` (0 is Compact, 1 is Comfortable).
/// Each metric resolves as `compact + (comfortable - compact) × level`, so rows, radii, icons and
/// text keep their ratios at every density. `tokens` sets any metric exactly, and `fontSize`
/// sets the chrome body text size. Compact (`level` 0, `spacing` 1, no tokens) resolves every
/// value to the literal compact value.
///
/// ```swift
/// let tight = DensityTokens(id: "tight", name: "Tight", level: -0.25, fontSize: 11.5,
///                           tokens: ["sidebarRowHeight": 22])
/// tight.resolve(compact: 24, comfortable: 32, token: "sidebarRowHeight") // 22
/// ```
public nonisolated struct DensityTokens: Sendable, Hashable, Codable, Identifiable {
    /// The stable key `appearance.density` stores.
    public var id: String
    /// The display name: a built-in's English name (the UI localizes built-ins by `id`), or the
    /// user's own name for a custom density.
    public var name: String
    /// The built-in this custom density was made from, if any.
    public var basedOn: String?
    /// Position on the compact (0) → comfortable (1) axis; below 0 is denser, above 1 roomier.
    public var level: Double
    /// The multiplier for padding and insets (`Metrics.space1`…`space6`); 1 keeps today's.
    public var spacing: Double
    /// The chrome body text size in points; nil follows `level`.
    public var fontSize: Double?
    /// Exact values by metric name (`MetricTunables` names such as `sidebarRowHeight`).
    public var tokens: [String: Double]

    /// The allowed `level` range.
    public static let levelRange: ClosedRange<Double> = -1...2.5
    /// The allowed `spacing` range.
    public static let spacingRange: ClosedRange<Double> = 0.5...2
    /// The allowed `fontSize` range in points.
    public static let fontSizeRange: ClosedRange<Double> = 9...20

    /// Makes a density, clamping each value into its range.
    /// - Parameters:
    ///   - id: The stable key.
    ///   - name: The display name.
    ///   - basedOn: The built-in it was made from.
    ///   - level: The compact→comfortable position (default 0, Compact).
    ///   - spacing: The padding multiplier (default 1).
    ///   - fontSize: The body text size, or nil to follow `level`.
    ///   - tokens: Exact metric values by name.
    public init(id: String, name: String, basedOn: String? = nil, level: Double = 0, spacing: Double = 1,
                fontSize: Double? = nil, tokens: [String: Double] = [:]) {
        self.id = id
        self.name = name
        self.basedOn = basedOn
        self.level = level.clamped(to: Self.levelRange)
        self.spacing = spacing.clamped(to: Self.spacingRange)
        self.fontSize = fontSize.map { $0.clamped(to: Self.fontSizeRange) }
        self.tokens = tokens.filter { $0.value.isFinite && $0.value >= 0 }
    }

    /// The family code that branches on two densities reads (`Density`): compact below level 0.5.
    public var family: Density { level < 0.5 ? .compact : .comfortable }

    /// Whether this density is a built-in preset.
    public var isBuiltIn: Bool { DensityPreset(rawValue: id) != nil }

    /// A metric's value at this density: `tokens[token]` when set, else the level's point between
    /// `compact` and `comfortable`, rounded to a whole point. Level 0 returns `compact` exactly
    /// and level 1 returns `comfortable` exactly.
    public func resolve(compact: CGFloat, comfortable: CGFloat, token: String? = nil) -> CGFloat {
        if let token, let exact = tokens[token] { return CGFloat(exact) }
        if level == 0 { return compact }
        if level == 1 { return comfortable }
        return (compact + (comfortable - compact) * CGFloat(level)).rounded()
    }

    /// The body text size at this density's level, before `fontSize`: 12 at Compact, 13 at
    /// Comfortable.
    public var levelBodySize: CGFloat { Self.textAtLevel(12, 13, level) }

    /// The body text size this density draws: `fontSize`, else the level's.
    public var bodySize: CGFloat { fontSize.map { CGFloat($0) } ?? levelBodySize }

    /// A text style's size at this density, from its compact and comfortable sizes: the level's
    /// point between them (half-point steps), scaled by `fontSize` over the level's body size
    /// when `fontSize` is set. Compact without `fontSize` returns `compact` exactly.
    public func textSize(compact: CGFloat, comfortable: CGFloat) -> CGFloat {
        let atLevel = Self.textAtLevel(compact, comfortable, level)
        guard let fontSize else { return atLevel }
        return Self.half(atLevel * CGFloat(fontSize) / levelBodySize)
    }

    /// A padding value at this density's `spacing`, in half-point steps; `spacing` 1 returns
    /// `value` exactly.
    public func space(_ value: CGFloat) -> CGFloat {
        spacing == 1 ? value : Self.half(value * CGFloat(spacing))
    }

    private static func textAtLevel(_ compact: CGFloat, _ comfortable: CGFloat, _ level: Double) -> CGFloat {
        if level == 0 { return compact }
        if level == 1 { return comfortable }
        return half(compact + (comfortable - compact) * CGFloat(level))
    }

    private static func half(_ value: CGFloat) -> CGFloat { (value * 2).rounded() / 2 }

    // MARK: Built-ins

    /// Today's Compact, the default.
    public static let compact = DensityPreset.compact.tokens
}

private extension Comparable {
    nonisolated func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
