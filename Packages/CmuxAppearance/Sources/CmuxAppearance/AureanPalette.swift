import Foundation

/// The canonical ``AppearancePalette`` implementation, carrying the exact token values
/// for each ``AureanPaletteVariant``.
///
/// Hex values are transcribed verbatim from the design's `tokens.css` (the source of
/// truth). The `warn` (gold `#E5C07B`) and `crit` (rust `#FF8A66`) signals are identical
/// across every variant by design; only negative space, sand, and the cool signals shift.
///
/// ```swift
/// let palette = AureanPalette(variant: .cool)        // cmux default
/// view.background(palette.surfacePrimary.color)
/// ```
public struct AureanPalette: AppearancePalette, Sendable, Hashable {
    public let surfacePrimary: AureanColor
    public let surfaceOff: AureanColor
    public let surfaceAbyssal: AureanColor
    public let text: AureanColor
    public let accent: AureanColor
    public let ok: AureanColor
    public let warn: AureanColor
    public let crit: AureanColor

    /// The temperature this palette was built from.
    public let variant: AureanPaletteVariant

    /// Builds the concrete palette for a temperature.
    /// - Parameter variant: The Aurean temperature; defaults to ``AureanPaletteVariant/cool``.
    public init(variant: AureanPaletteVariant = .cool) {
        self.variant = variant
        // Signals shared across all palettes (muscle-memory invariants).
        self.warn = AureanColor(hex: "#E5C07B") // gold
        self.crit = AureanColor(hex: "#FF8A66") // rust
        switch variant {
        case .cool:
            surfacePrimary = AureanColor(hex: "#161819")
            surfaceOff = AureanColor(hex: "#121314")
            surfaceAbyssal = AureanColor(hex: "#0E1011")
            text = AureanColor(hex: "#C4C7CC")
            accent = AureanColor(hex: "#B8D8E8")
            ok = AureanColor(hex: "#B6D4B0")
        case .dune:
            surfacePrimary = AureanColor(hex: "#1A1817")
            surfaceOff = AureanColor(hex: "#141312")
            surfaceAbyssal = AureanColor(hex: "#100E0D")
            text = AureanColor(hex: "#D2C0B0")
            accent = AureanColor(hex: "#AEE2EA")
            ok = AureanColor(hex: "#C5E1A5")
        case .warm:
            surfacePrimary = AureanColor(hex: "#1E1A15")
            surfaceOff = AureanColor(hex: "#18140F")
            surfaceAbyssal = AureanColor(hex: "#140F0A")
            text = AureanColor(hex: "#E0CAB2")
            accent = AureanColor(hex: "#B8DDDC")
            ok = AureanColor(hex: "#D0DFA5")
        case .obsidian:
            surfacePrimary = AureanColor(hex: "#15171A")
            surfaceOff = AureanColor(hex: "#101214")
            surfaceAbyssal = AureanColor(hex: "#0B0D0F")
            text = AureanColor(hex: "#C9D0D4")
            accent = AureanColor(hex: "#A3C9D6")
            ok = AureanColor(hex: "#B6D8B8")
        }
    }
}
