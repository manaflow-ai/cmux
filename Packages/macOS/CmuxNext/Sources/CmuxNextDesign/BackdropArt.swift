public import AppKit

/// A bundled public-domain painting available behind the window material.
/// Game art is never part of this catalog.
public nonisolated enum BackdropArt: String, CaseIterable, Sendable {
    /// Vincent van Gogh's 1889 painting from the Met Open Access collection.
    case wheatField = "wheat-field-with-cypresses"
    case saintCatherine = "met-saint-catherine-436908"
    case portraitAtCasement = "met-woman-man-casement-436896"
    case womenPickingOlives = "met-women-picking-olives-436536"
    case sunflowers = "met-sunflowers-436524"

    /// The authored layout and tonal hints used by the backdrop renderer.
    public nonisolated var metadata: BackdropArtMetadata {
        switch self {
        case .wheatField:
            return BackdropArtMetadata(
                focalAnchor: .init(x: 0.72, y: 0.46),
                tone: .light,
                dominantPalette: [
                    .init(red: 106, green: 117, blue: 102),
                    .init(red: 208, green: 182, blue: 111),
                    .init(red: 73, green: 88, blue: 117)
                ],
                quietZone: .init(x: 0.02, y: 0.08, width: 0.38, height: 0.82)
            )
        case .saintCatherine:
            return BackdropArtMetadata(
                focalAnchor: .init(x: 0.52, y: 0.43),
                tone: .light,
                dominantPalette: [
                    .init(red: 190, green: 154, blue: 108),
                    .init(red: 78, green: 78, blue: 68),
                    .init(red: 151, green: 101, blue: 73)
                ],
                quietZone: .init(x: 0.06, y: 0.70, width: 0.88, height: 0.24)
            )
        case .portraitAtCasement:
            return BackdropArtMetadata(
                focalAnchor: .init(x: 0.57, y: 0.43),
                tone: .dark,
                dominantPalette: [
                    .init(red: 83, green: 56, blue: 37),
                    .init(red: 159, green: 126, blue: 89),
                    .init(red: 47, green: 46, blue: 41)
                ],
                quietZone: .init(x: 0.03, y: 0.04, width: 0.36, height: 0.88)
            )
        case .womenPickingOlives:
            return BackdropArtMetadata(
                focalAnchor: .init(x: 0.55, y: 0.50),
                tone: .light,
                dominantPalette: [
                    .init(red: 125, green: 121, blue: 96),
                    .init(red: 76, green: 94, blue: 61),
                    .init(red: 180, green: 159, blue: 113)
                ],
                quietZone: .init(x: 0.02, y: 0.07, width: 0.38, height: 0.84)
            )
        case .sunflowers:
            return BackdropArtMetadata(
                focalAnchor: .init(x: 0.58, y: 0.46),
                tone: .light,
                dominantPalette: [
                    .init(red: 98, green: 103, blue: 83),
                    .init(red: 202, green: 164, blue: 48),
                    .init(red: 43, green: 55, blue: 47)
                ],
                quietZone: .init(x: 0.02, y: 0.08, width: 0.38, height: 0.82)
            )
        }
    }

    public var title: String {
        switch self {
        case .wheatField: String(localized: "backdrop.wheatField.title", defaultValue: "Wheat Field with Cypresses", bundle: .module)
        case .saintCatherine: String(localized: "backdrop.saintCatherine.title", defaultValue: "Saint Catherine of Alexandria", bundle: .module)
        case .portraitAtCasement: String(localized: "backdrop.portraitAtCasement.title", defaultValue: "Portrait at a Casement", bundle: .module)
        case .womenPickingOlives: String(localized: "backdrop.womenPickingOlives.title", defaultValue: "Women Picking Olives", bundle: .module)
        case .sunflowers: String(localized: "backdrop.sunflowers.title", defaultValue: "Sunflowers", bundle: .module)
        }
    }

    /// The museum's canonical attribution, kept in its original form.
    public var attribution: String {
        switch self {
        case .wheatField: String(localized: "backdrop.wheatField.attribution", defaultValue: "Wheat Field with Cypresses · Vincent van Gogh · 1889 · The Metropolitan Museum of Art · CC0", bundle: .module)
        case .saintCatherine: String(localized: "backdrop.saintCatherine.attribution", defaultValue: "Saint Catherine of Alexandria · Pietro Lorenzetti · ca. 1342 · The Metropolitan Museum of Art · CC0", bundle: .module)
        case .portraitAtCasement: String(localized: "backdrop.portraitAtCasement.attribution", defaultValue: "Portrait of a Woman with a Man at a Casement · Fra Filippo Lippi · ca. 1440 · The Metropolitan Museum of Art · CC0", bundle: .module)
        case .womenPickingOlives: String(localized: "backdrop.womenPickingOlives.attribution", defaultValue: "Women Picking Olives · Vincent van Gogh · 1889 · The Metropolitan Museum of Art · CC0", bundle: .module)
        case .sunflowers: String(localized: "backdrop.sunflowers.attribution", defaultValue: "Sunflowers · Vincent van Gogh · 1887 · The Metropolitan Museum of Art · CC0", bundle: .module)
        }
    }

    /// The museum's artwork page, including the Open Access designation.
    public var sourceURL: URL {
        let id: String
        switch self {
        case .wheatField: id = "436535"
        case .saintCatherine: id = "436908"
        case .portraitAtCasement: id = "436896"
        case .womenPickingOlives: id = "436536"
        case .sunflowers: id = "436524"
        }
        return URL(string: "https://www.metmuseum.org/art/collection/search/\(id)")!
    }

    /// Loads the packaged image. A missing resource safely paints no art.
    /// - Returns: The painting image, or nil if the bundle is incomplete.
    @MainActor public func image() -> NSImage? {
        guard let url = Bundle.module.url(forResource: rawValue, withExtension: "jpg") else { return nil }
        return NSImage(contentsOf: url)
    }
}
