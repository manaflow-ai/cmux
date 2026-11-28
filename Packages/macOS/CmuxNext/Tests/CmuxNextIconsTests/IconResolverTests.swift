@testable import CmuxNextIcons
import Testing

/// Names the pack lacks fall back to SF Symbols.
struct IconResolverTests {
    @Test func anUnknownNameResolvesToThePlaceholderSymbol() {
        let resolved = IconPack.bundled.resolve(IconName("no.such.icon"), style: .line)
        #expect(resolved == .system(IconResolution.unknownSymbol))
        #expect(resolved == .system("questionmark.square.dashed"))
    }

    @Test func aCatalogNameMissingFromThePackResolvesToItsSymbol() throws {
        let entry = try #require(IconCatalog.bundled.entry(for: .actionClose))
        let resolved = IconPack(icons: [:]).resolve(.actionClose, style: .line)
        #expect(resolved == .system(entry.sf))
    }
}
