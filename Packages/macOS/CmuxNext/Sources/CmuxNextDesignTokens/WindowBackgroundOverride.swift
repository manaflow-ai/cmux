/// cmux's own window background in cmux.json (`appearance.backgroundOpacity`
/// and `appearance.backgroundBlur`), laid over Ghostty's
/// `background-opacity` and `background-blur`.
///
/// ``resolved(backgroundOpacity:backgroundBlur:)`` is the one rule: the
/// Ghostty config the terminal surfaces get and the theme tokens the window
/// draws from both apply it, so ``WindowBackdrop`` and the terminal agree.
/// Applying it to values it already resolved changes nothing.
///
/// ```swift
/// let override = WindowBackgroundOverride(opacity: 0.7, material: .glass)
/// override.resolved(backgroundOpacity: 1, backgroundBlur: 0) // (0.7, -1)
/// ```
public nonisolated struct WindowBackgroundOverride: Hashable, Sendable {
    /// `appearance.backgroundOpacity`, 0...1; nil keeps Ghostty's.
    public var opacity: Double?
    /// `appearance.backgroundBlur`; nil keeps Ghostty's.
    public var material: WindowMaterialChoice?

    /// The opacity a chosen material (frosted or glass) gets when neither
    /// cmux.json nor the Ghostty config makes the window translucent:
    /// picking a material asks for translucency, and at opacity 1 the tint
    /// would hide it. `"none"` does not get it: it only drops the blur.
    public static let defaultTranslucentOpacity = 0.8

    /// The blur radius ``WindowMaterialChoice/frosted`` gives a config with
    /// none (Ghostty's radius for `background-blur = true`), so the window
    /// reads as frosted rather than plainly see-through.
    public static let defaultFrostedRadius = 20

    /// - Parameter opacity: `appearance.backgroundOpacity`; nil (the
    ///   default) keeps the Ghostty config's.
    /// - Parameter material: `appearance.backgroundBlur`; nil (the default)
    ///   keeps the Ghostty config's.
    public init(opacity: Double? = nil, material: WindowMaterialChoice? = nil) {
        self.opacity = opacity.map { min(max($0, 0), 1) }
        self.material = material
    }

    /// The opacity and blur the window uses, from the Ghostty config's.
    ///
    /// - Parameter backgroundOpacity: Ghostty's `background-opacity`.
    /// - Parameter backgroundBlur: Ghostty's `background-blur` in its C
    ///   encoding (0 off, > 0 radius, -1/-2 macOS glass styles).
    /// - Returns: The resolved pair, in the same encodings. With no override
    ///   it is the input.
    public func resolved(backgroundOpacity: Double, backgroundBlur: Int) -> (backgroundOpacity: Double, backgroundBlur: Int) {
        let blur: Int
        switch material {
        case nil: blur = backgroundBlur
        case .frosted?: blur = backgroundBlur > 0 ? backgroundBlur : Self.defaultFrostedRadius
        case .glass?: blur = -1
        case .glassClear?: blur = -2
        case .unblurred?: blur = 0
        }
        if let opacity { return (opacity, blur) }
        // A material asks for translucency; "none" only drops the blur.
        if let material, material != .unblurred, backgroundOpacity >= 1 { return (Self.defaultTranslucentOpacity, blur) }
        return (min(max(backgroundOpacity, 0), 1), blur)
    }
}
