public import CmuxNextDesignTokens
public import Foundation

/// The groups the background picker shows bundled art in, in picker order.
public nonisolated enum BackdropArtCollection: String, CaseIterable, Equatable, Sendable {
    case darkArt
    case museumIcons
    case calm
    case dore

    public var title: String {
        switch self {
        case .darkArt: String(localized: "backdrop.collection.darkArt", defaultValue: "Dark Art", bundle: .module)
        case .museumIcons: String(localized: "backdrop.collection.museumIcons", defaultValue: "Museum Icons", bundle: .module)
        case .calm: String(localized: "backdrop.collection.calm", defaultValue: "Calm", bundle: .module)
        case .dore: String(localized: "backdrop.collection.dore", defaultValue: "Doré", bundle: .module)
        }
    }
}

public nonisolated extension BackdropArt {
    /// A bundled work by id, also accepting the ids of the earlier set (figure drawings and Met
    /// paintings), which a cmux.json written before cx-t2x.7 may still name.
    init?(id: String) {
        if let art = BackdropArt(rawValue: id) {
            self = art
        } else if let replacement = Self.retiredIDs[id] {
            self = replacement
        } else {
            return nil
        }
    }

    /// Ids of works taken out of the set without a stand-in: the goriest and grimmest pieces (Leo,
    /// 2026-10-19: too depressing for a backdrop). A cmux.json or workspace that still names one
    /// shows the default background, with no invalid-value diagnostic.
    static let removedIDs: Set<String> = [
        "bocklin-isle-of-the-dead", "bocklin-self-portrait-death", "bosch-garden-right", "bruegel-triumph-death",
        "bundy-death-general", "caravaggio-david-goliath", "caravaggio-medusa", "dore-flood",
        "draper-lament-icarus", "durer-knight-death-devil", "ensor-skeleton-painter", "fuseli-nightmare",
        "fuseli-nightmare-2", "gentileschi-judith", "gericault-raft-of-the-medusa", "gerome-pollice-verso",
        "goya-saturn", "goya-witches-sabbath", "hiremy-hirschl-souls-of-acheron", "klimt-death-and-life",
        "klimt-judith", "klimt-medicine", "millais-ophelia", "moreau-apparition", "repin-ivan",
        "schiele-death-and-the-maiden", "van-gogh-skeleton-cigarette", "vereshchagin-apotheosis-war"
    ]

    /// Each retired id and the work that now stands in for it.
    static let retiredIDs: [String: BackdropArt] = [
        "wheat-field-with-cypresses": .vanGoghWheatFieldCypresses,
        "met-sunflowers-436524": .vanGoghSunflowers,
        "met-women-picking-olives-436536": .vanGoghAlmondBlossom,
        "met-saint-catherine-436908": .raphaelSistineMadonna,
        "met-woman-man-casement-436896": .vermeerPearlEarring,
        "nga-degas-halevy-standing-66489": .degasBlueDancers,
        "nga-degas-dancer-from-behind-32137": .degasGreenDancers,
        "nga-carpaccio-groups-of-male-figures-73858": .bruegelFallRebelAngels,
        "nga-perino-del-vaga-figure-studies-57613": .michelangeloCreationOfAdam,
        "nga-rubens-battle-of-nude-men-63034": .rubensStFrancisXavier,
        "nga-teniers-market-figures-62615": .bruegelHuntersSnow,
    ]

    var collection: BackdropArtCollection { entry.collection }

    var metadata: BackdropArtMetadata { entry.metadata }

    var artist: String { entry.artist }

    /// Whether the full image ships in the app; the rest download on first pick.
    var isBundled: Bool { entry.bundled }

    /// The bundled art in picker order: by collection, darkest works first within each.
    static let pickerOrder: [BackdropArt] = BackdropArtCollection.allCases.flatMap { collection in
        allCases.filter { $0.collection == collection }
    }

    /// The picker label: "Title — Artist".
    var label: String {
        String(localized: "backdrop.label", defaultValue: "%1$@ — %2$@", bundle: .module)
            .replacingOccurrences(of: "%1$@", with: title)
            .replacingOccurrences(of: "%2$@", with: artist)
    }

    /// The credit shown below the thumbnail: title, artist, date, museum and license.
    var attribution: String {
        [title, artist, entry.year, entry.museum,
         String(localized: "backdrop.publicDomain", defaultValue: "Public domain", bundle: .module)]
            .joined(separator: " · ")
    }

    /// The Wikimedia Commons file page, with the image's license.
    var sourceURL: URL { URL(string: entry.source) ?? URL(fileURLWithPath: "/dev/null") }
}
