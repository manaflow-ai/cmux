// Follows schemas/design-scale/design-scale.json: change the schema and this token together.
// scripts/cmux-next/check-surface-roles.py checks these constants against the web scale's schema.

/// The regular translucent material shared by non-chat transient surfaces.
/// Shapes, interaction and accessibility fallbacks stay with their platform owners.
public nonisolated struct TransientMaterial: Sendable, Equatable {
    /// The shipped material; gallery alternatives never change this value.
    public static let standard = TransientMaterial()

    /// Shared dark veil alpha.
    public let darkVeilAlpha: Double = 0.42
    /// Shared light veil alpha.
    public let lightVeilAlpha: Double = 0.55
    /// Shared dark rim top.
    public let darkRimTop: Double = 0.3
    /// Shared dark rim bottom.
    public let darkRimBottom: Double = 0.06
    /// Shared light rim top.
    public let lightRimTop: Double = 0.85
    /// Shared light rim bottom.
    public let lightRimBottom: Double = 0.1
    /// Shared host veil.
    public let hostVeil: Double = 0.4
    /// Shared native tint strength.
    public let nativeTintStrength: Double = 1.25
    /// Shared web tint.
    public let webTint: Double = 78
    /// Shared web blur.
    public let webBlur: Double = 32
    /// Shared web saturation.
    public let webSaturation: Double = 1.6
    /// Shared neutral dark.
    public let neutralDark: Double = 0.11
    /// Shared neutral light.
    public let neutralLight: Double = 0.99

    private init() {}
}
