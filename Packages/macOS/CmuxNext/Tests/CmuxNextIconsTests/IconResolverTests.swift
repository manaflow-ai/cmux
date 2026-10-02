@testable import CmuxNextIcons
import Testing

/// Names the pack lacks fall back to SF Symbols.
struct IconResolverTests {
    @Test func anUnknownNameResolvesToThePlaceholderSymbol() {
        let resolved = IconResolver.resolve(IconName("no.such.icon"), style: .line)
        #expect(resolved == .system(IconResolver.unknownSymbol))
        #expect(resolved == .system("questionmark.square.dashed"))
    }

    @Test func aCatalogNameMissingFromThePackResolvesToItsSymbol() throws {
        let entry = try #require(IconCatalog.bundled.entry(for: .actionClose))
        let resolved = IconResolver.resolve(.actionClose, style: .line, pack: IconPack(icons: [:]))
        #expect(resolved == .system(entry.sf))
    }
}
