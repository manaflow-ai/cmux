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

    /// The `UserDefaults` key under which the active variant is persisted.
    ///
    /// Shared so the settings picker, the app's ambient AppKit color helpers, and the
    /// SwiftUI theme owner all read and write the same key with no drift.
    public static let userDefaultsKey = "aureanPaletteVariant"

    /// The concrete palette of colors for this temperature.
    ///
    /// Returns a shared cached value, so reading a variant's palette on a hot path (drop
    /// targets, focus rings) costs a dictionary lookup rather than re-parsing the tokens.
    public var palette: AureanPalette { Self.cachedPalettes[self] ?? AureanPalette(variant: self) }

    private static let cachedPalettes: [AureanPaletteVariant: AureanPalette] =
        Dictionary(uniqueKeysWithValues: AureanPaletteVariant.allCases.map { ($0, AureanPalette(variant: $0)) })
}
