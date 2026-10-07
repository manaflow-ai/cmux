import Foundation
import Testing
@testable import CmuxMobileWire

@Suite struct CatalogTests {
    let fixtures = Fixtures()

    @Test func v1EqualsCatalogJSON() throws {
        let file = try JSONDecoder().decode(MobileCatalog.self, from: fixtures.data("catalog.json"))
        #expect(file == MobileCatalog.v1)
    }

    @Test func namesAreUniqueAndLookupsWork() {
        let names = MobileCatalog.v1.families.flatMap { $0.messages.map(\.name) }
        #expect(Set(names).count == names.count)
        #expect(MobileCatalog.v1.message(named: "terminal.viewport")?.kind == .message)
        #expect(MobileCatalog.v1.family(ofMessage: "feed.answer")?.name == "feed")
        #expect(MobileCatalog.v1.message(named: "nope") == nil)
    }

    @Test func everyMessageHasAFixture() throws {
        var covered = Set<String>()
        for file in try fixtures.familyFiles() {
            for c in try #require(fixtures.json("fixtures/\(file)")["cases"]?.arrayValue) {
                if let m = c["message"]?.stringValue { covered.insert(m) }
            }
        }
        for r in try #require(fixtures.json("fixtures/binary.json")["records"]?.arrayValue) {
            if let m = r["message"]?.stringValue { covered.insert(m) }
        }
        for family in MobileCatalog.v1.families {
            for message in family.messages {
                #expect(covered.contains(message.name), "\(message.name) has no fixture")
            }
        }
    }
}
