@testable import CmuxNextIcons
import Testing

/// The bundled pack and catalog agree with the generated `IconName` members.
struct IconPackTests {
    @Test func theBundledPackAndCatalogLoad() {
        #expect(IconPack.bundled.grid == 24)
        #expect(!IconPack.bundled.icons.isEmpty)
        #expect(IconCatalog.bundled.entries.count == IconName.catalog.count)
    }

    @Test func everyCatalogEntryHasLineAndSolidDrawings() {
        for entry in IconCatalog.bundled.entries {
            let drawing = IconPack.bundled.drawing(for: entry.name)
            #expect(drawing != nil, "\(entry.name.rawValue) is not in the pack")
            #expect(drawing?.line.isEmpty == false, "\(entry.name.rawValue) has no Line drawing")
            #expect(drawing?.solid.isEmpty == false, "\(entry.name.rawValue) has no Solid drawing")
            #expect(IconResolver.resolve(entry.name, style: .line) == .drawing(drawing?.line ?? []))
            #expect(IconResolver.resolve(entry.name, style: .solid) == .drawing(drawing?.solid ?? []))
        }
    }

    @Test func everyGeneratedNameIsInThePackAndCatalog() {
        for name in IconName.catalog {
            #expect(IconPack.bundled.drawing(for: name) != nil, "\(name.rawValue) is not in the pack")
            #expect(IconCatalog.bundled.entry(for: name) != nil, "\(name.rawValue) is not in the catalog")
        }
    }

    @Test func everyLayerPathParses() {
        for (name, drawing) in IconPack.bundled.icons {
            for layer in drawing.line + drawing.solid + (drawing.cat ?? []) {
                #expect(IconPath.cgPath(layer.d) != nil, "\(name): \(layer.d)")
            }
        }
    }

    @Test func catReplacesLineOnly() throws {
        let (name, drawing) = try #require(IconPack.bundled.icons.first { $0.value.cat != nil })
        let cat = try #require(drawing.cat)
        let icon = IconName(name)
        #expect(IconResolver.resolve(icon, style: .line, accent: .cat) == .drawing(cat))
        #expect(IconResolver.resolve(icon, style: .solid, accent: .cat) == .drawing(drawing.solid))
        #expect(IconResolver.resolve(icon, style: .line, accent: .none) == .drawing(drawing.line))
    }

    @Test func catFallsBackToLineWithoutACatDrawing() {
        let line = [IconLayer(d: "M4 4L20 20", op: .stroke)]
        let solid = [IconLayer(d: "M4 4L20 20", op: .stroke, width: 2)]
        let pack = IconPack(icons: ["test.plain": IconDrawing(line: line, solid: solid)])
        #expect(IconResolver.resolve(IconName("test.plain"), style: .line, accent: .cat, pack: pack) == .drawing(line))
    }

    @Test func denseIconsDrawSolidBelowThirteenPoints() throws {
        let entry = try #require(IconCatalog.bundled.entries.first { $0.denseStyle == .solid })
        #expect(IconCatalog.bundled.style(.line, for: entry.name, size: 12) == .solid)
        #expect(IconCatalog.bundled.style(.line, for: entry.name, size: 13) == .line)
        #expect(IconCatalog.bundled.style(.line, for: .actionClose, size: 12) == .line)
    }
}
