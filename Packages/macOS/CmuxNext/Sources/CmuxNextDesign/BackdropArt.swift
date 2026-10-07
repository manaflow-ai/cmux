public import AppKit

/// A bundled public-domain artwork available behind the window material:
/// paintings from the Met and figure drawings from the National Gallery of
/// Art, all CC0 (Resources/ARTWORK.md). Game art is never part of this catalog.
public nonisolated enum BackdropArt: String, CaseIterable, Sendable {
    /// Vincent van Gogh's 1889 painting from the Met Open Access collection.
    case wheatField = "wheat-field-with-cypresses"
    case saintCatherine = "met-saint-catherine-436908"
    case portraitAtCasement = "met-woman-man-casement-436896"
    case womenPickingOlives = "met-women-picking-olives-436536"
    case sunflowers = "met-sunflowers-436524"
    /// Figure drawings: grayscale derivatives, so the theme's tint sets their hue.
    case degasHalevy = "nga-degas-halevy-standing-66489"
    case degasDancer = "nga-degas-dancer-from-behind-32137"
    case carpaccioFigures = "nga-carpaccio-groups-of-male-figures-73858"
    case perinoFigureStudies = "nga-perino-del-vaga-figure-studies-57613"
    case rubensBattle = "nga-rubens-battle-of-nude-men-63034"
    case teniersMarket = "nga-teniers-market-figures-62615"

    /// The art a window shows when `appearance.background` is unset.
    public static let defaultSelection = BackdropArt.degasHalevy

    /// The group the art belongs to in the background picker.
    public var collection: BackdropArtCollection {
        switch self {
        case .wheatField, .saintCatherine, .portraitAtCasement, .womenPickingOlives, .sunflowers: .paintings
        case .degasHalevy, .degasDancer, .carpaccioFigures, .perinoFigureStudies, .rubensBattle, .teniersMarket: .figureDrawings
        }
    }

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
        case .degasHalevy:
            return .drawing(focal: (0.50, 0.42), tone: .light, grays: [187, 129, 204], quiet: (0.02, 0.04, 0.96, 0.18))
        case .degasDancer:
            return .drawing(focal: (0.22, 0.45), tone: .dark, grays: [115, 83, 133], quiet: (0.40, 0.04, 0.58, 0.50))
        case .carpaccioFigures:
            return .drawing(focal: (0.62, 0.58), tone: .light, grays: [204, 150, 220], quiet: (0.02, 0.04, 0.46, 0.50))
        case .perinoFigureStudies:
            return .drawing(focal: (0.50, 0.45), tone: .light, grays: [158, 124, 183], quiet: (0.04, 0.86, 0.92, 0.12))
        case .rubensBattle:
            return .drawing(focal: (0.55, 0.45), tone: .light, grays: [145, 123, 165], quiet: (0.02, 0.80, 0.50, 0.18))
        case .teniersMarket:
            return .drawing(focal: (0.45, 0.55), tone: .light, grays: [211, 161, 228], quiet: (0.36, 0.02, 0.30, 0.20))
        }
    }

    public var title: String {
        switch self {
        case .wheatField: String(localized: "backdrop.wheatField.title", defaultValue: "Wheat Field with Cypresses", bundle: .module)
        case .saintCatherine: String(localized: "backdrop.saintCatherine.title", defaultValue: "Saint Catherine of Alexandria", bundle: .module)
        case .portraitAtCasement: String(localized: "backdrop.portraitAtCasement.title", defaultValue: "Portrait at a Casement", bundle: .module)
        case .womenPickingOlives: String(localized: "backdrop.womenPickingOlives.title", defaultValue: "Women Picking Olives", bundle: .module)
        case .sunflowers: String(localized: "backdrop.sunflowers.title", defaultValue: "Sunflowers", bundle: .module)
        case .degasHalevy: String(localized: "backdrop.degasHalevy.title", defaultValue: "Three Studies of Ludovic Halévy Standing", bundle: .module)
        case .degasDancer: String(localized: "backdrop.degasDancer.title", defaultValue: "Dancer Seen from Behind", bundle: .module)
        case .carpaccioFigures: String(localized: "backdrop.carpaccioFigures.title", defaultValue: "Groups of Male Figures", bundle: .module)
        case .perinoFigureStudies: String(localized: "backdrop.perinoFigureStudies.title", defaultValue: "Figure Studies", bundle: .module)
        case .rubensBattle: String(localized: "backdrop.rubensBattle.title", defaultValue: "Battle of Nude Men", bundle: .module)
        case .teniersMarket: String(localized: "backdrop.teniersMarket.title", defaultValue: "Studies of Market Figures", bundle: .module)
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
        case .degasHalevy: String(localized: "backdrop.degasHalevy.attribution", defaultValue: "Three Studies of Ludovic Halévy Standing · Edgar Degas · c. 1880 · National Gallery of Art · CC0", bundle: .module)
        case .degasDancer: String(localized: "backdrop.degasDancer.attribution", defaultValue: "Dancer Seen from Behind and Three Studies of Feet · Edgar Degas · c. 1878 · National Gallery of Art · CC0", bundle: .module)
        case .carpaccioFigures: String(localized: "backdrop.carpaccioFigures.attribution", defaultValue: "Groups of Male Figures · Vittore Carpaccio · c. 1514 · National Gallery of Art · CC0", bundle: .module)
        case .perinoFigureStudies: String(localized: "backdrop.perinoFigureStudies.attribution", defaultValue: "Figure Studies · Perino del Vaga · c. 1530/1540 · National Gallery of Art · CC0", bundle: .module)
        case .rubensBattle: String(localized: "backdrop.rubensBattle.attribution", defaultValue: "Battle of Nude Men · Sir Peter Paul Rubens · National Gallery of Art · CC0", bundle: .module)
        case .teniersMarket: String(localized: "backdrop.teniersMarket.attribution", defaultValue: "Studies of Market Figures · David Teniers the Younger · National Gallery of Art · CC0", bundle: .module)
        }
    }

    /// The museum's artwork page, including the Open Access designation.
    public var sourceURL: URL {
        switch self {
        case .wheatField: Self.met("436535")
        case .saintCatherine: Self.met("436908")
        case .portraitAtCasement: Self.met("436896")
        case .womenPickingOlives: Self.met("436536")
        case .sunflowers: Self.met("436524")
        case .degasHalevy: Self.nga("66489")
        case .degasDancer: Self.nga("32137")
        case .carpaccioFigures: Self.nga("73858")
        case .perinoFigureStudies: Self.nga("57613")
        case .rubensBattle: Self.nga("63034")
        case .teniersMarket: Self.nga("62615")
        }
    }

    private static func met(_ id: String) -> URL { page("https://www.metmuseum.org/art/collection/search/\(id)") }

    private static func nga(_ id: String) -> URL { page("https://www.nga.gov/collection/art-object-page.\(id).html") }

    /// A constant museum URL with a numeric id.
    private static func page(_ string: String) -> URL { URL(string: string)! }

    /// Loads the packaged image. A missing resource safely paints no art.
    /// - Returns: The painting image, or nil if the bundle is incomplete.
    @MainActor public func image() -> NSImage? {
        imageURL.flatMap(NSImage.init(contentsOf:))
    }

    /// The packaged image file, or nil if the bundle is incomplete.
    public nonisolated var imageURL: URL? {
        Bundle.module.url(forResource: rawValue, withExtension: "jpg")
    }
}

/// The groups the background picker shows bundled art in.
public nonisolated enum BackdropArtCollection: String, CaseIterable, Equatable, Sendable {
    case paintings
    /// Life drawings and gesture studies, which sit quietly behind a terminal.
    case figureDrawings
}
