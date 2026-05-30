import Foundation

/// The four Aurean palette temperatures shipped by the design.
///
/// All variants share the same signal hues for `warn`/`crit`; they differ only in the
/// temperature of the negative space and the tone of the sand text (and a slight shift
/// in `accent`/`ok` warmth). ``cool`` is the cmux default; ``dune`` is the canonical
/// Aurean Protocol base.
public enum AureanPaletteVariant: String, Sendable, CaseIterable, Codable {
    /// Cool blue-grey negative space — the cmux default delivery.
    case cool
    /// Warm sand/desert base — the canonical Aurean Protocol palette.
    case dune
    /// Warmest amber negative space.
    case warm
    /// Cold near-black with cool sand — maximum contrast.
    case obsidian

    /// The concrete palette of colors for this temperature.
    public var palette: AureanPalette { AureanPalette(variant: self) }
}
