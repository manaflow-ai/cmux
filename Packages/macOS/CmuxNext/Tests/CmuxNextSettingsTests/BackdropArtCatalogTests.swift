import AppKit
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// The bundled backdrop art (cx-t2x.7): well-known public-domain paintings in four picker
/// collections, labelled "Title — Artist", each a 1600×1000 image that decodes, and every id a
/// cmux.json saved before the set changed still choosing art.
@Suite struct BackdropArtCatalogTests {
    /// Ids the earlier bundled set wrote to `appearance.background` and `appearance.backdropArt`.
    static let retiredIDs = [
        "wheat-field-with-cypresses", "met-saint-catherine-436908", "met-woman-man-casement-436896",
        "met-women-picking-olives-436536", "met-sunflowers-436524", "nga-degas-halevy-standing-66489",
        "nga-degas-dancer-from-behind-32137", "nga-carpaccio-groups-of-male-figures-73858",
        "nga-perino-del-vaga-figure-studies-57613", "nga-rubens-battle-of-nude-men-63034",
        "nga-teniers-market-figures-62615",
    ]

    @Test func thePickerGroupsArtIntoFourCollections() {
        let collections = BackdropCatalog.bundled.compactMap { choice -> String? in
            if case .art(let art) = choice { return art.collection.rawValue }
            return nil
        }
        var order: [String] = []
        for collection in collections where order.last != collection { order.append(collection) }
        #expect(order == ["darkArt", "museumIcons", "calm", "dore"])
    }

    @Test func everyArtChoiceIsLabelledTitleAndArtist() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: BackdropSelectionSetting().configPath))
        guard case .choice(let choices) = descriptor.kind else {
            Issue.record("appearance.background is not a choice")
            return
        }
        let art = choices.filter { BackdropArt(rawValue: $0.value) != nil }
        #expect(art.count >= 60)
        for choice in art {
            let parts = choice.title.components(separatedBy: " — ")
            #expect(parts.count == 2 && parts.allSatisfy { !$0.isEmpty }, "\(choice.value): \(choice.title)")
        }
    }

    @Test(arguments: retiredIDs)
    func aRetiredIDStillChoosesArt(id: String) {
        for path in [["appearance", "background"], ["appearance", "backdropArt"]] {
            let root = JSONValue.object([path[0]: .object([path[1]: .string(id)])])
            let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
            #expect(snapshot.backdropArt != nil, "\(path.joined(separator: ".")) = \(id)")
            #expect(!snapshot.diagnostics.contains { $0.path.hasPrefix("appearance.") }, "\(id)")
        }
    }

    /// A cmux.json that still names a work taken out of the set (Goya's Saturn Devouring His Son,
    /// Gentileschi's Judith, ...) shows the default background on either key, with no invalid-value
    /// diagnostic, and the picker no longer offers it.
    @Test(arguments: ["goya-saturn", "gentileschi-judith", "bocklin-isle-of-the-dead"])
    func aRemovedWorkFallsBackToTheDefaultBackground(id: String) {
        #expect(BackdropArt(id: id) == nil)
        #expect(!BackdropCatalog.bundled.contains { $0.id == id })
        for path in [["appearance", "background"], ["appearance", "backdropArt"]] {
            let root = JSONValue.object([path[0]: .object([path[1]: .string(id)])])
            let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
            #expect(snapshot.backdropSelection == BackdropSelectionSetting.defaultSelection, "\(path) = \(id)")
            #expect(snapshot.backdropArt == BackdropSelectionSetting.defaultArt, "\(path) = \(id)")
            #expect(!snapshot.diagnostics.contains { $0.path.hasPrefix("appearance.") }, "\(snapshot.diagnostics)")
        }
        #expect(BackdropArt.removedIDs.allSatisfy { BackdropArt(rawValue: $0) == nil })
    }

    /// Every work ships a small thumbnail (the picker and the first frame); only the starter set
    /// ships its full image, and the rest download on first pick (``BackdropArtDownloads``).
    @MainActor @Test(arguments: BackdropArt.allCases)
    func everyWorkShipsAThumbnailAndTheStarterSetShipsItsImage(art: BackdropArt) throws {
        let thumbnail = try #require(art.thumbnailURL.flatMap(NSImage.init(contentsOf:)), "\(art.rawValue) has no thumbnail")
        #expect(thumbnail.representations.first?.pixelsWide == 480, "\(art.rawValue) thumbnail")
        guard art.isBundled else { return }
        let image = try #require(art.image(), "\(art.rawValue) is missing or does not decode")
        let rep = try #require(image.representations.first)
        #expect(rep.pixelsWide == 1600 && rep.pixelsHigh == 1000, "\(art.rawValue): \(rep.pixelsWide)×\(rep.pixelsHigh)")
    }

    @MainActor @Test func aStarterSetOfDarkWorksShipsInTheApp() {
        let bundled = BackdropArt.allCases.filter(\.isBundled)
        #expect((12...24).contains(bundled.count))
        #expect(bundled.allSatisfy { $0.metadata.tone == .dark })
    }
}
