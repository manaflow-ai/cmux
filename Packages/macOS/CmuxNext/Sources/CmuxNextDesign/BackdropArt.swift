public import AppKit

/// A bundled public-domain painting available behind the window material.
/// Game art is never part of this catalog.
public enum BackdropArt: String, CaseIterable, Sendable {
    /// Vincent van Gogh's 1889 painting from the Met Open Access collection.
    case wheatField = "wheat-field-with-cypresses"
    case saintCatherine = "met-saint-catherine-436908"
    case portraitAtCasement = "met-woman-man-casement-436896"
    case womenPickingOlives = "met-women-picking-olives-436536"
    case sunflowers = "met-sunflowers-436524"

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
