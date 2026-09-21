import Foundation
import Testing
@testable import CmuxBrowser

@Suite("Browser import destination resolver")
struct BrowserImportDestinationResolverTests {
    @Test func UUIDSelectionWinsAndAmbiguousNamesFailClosed() throws {
        let profiles = [
            BrowserProfileDefinition(id: UUID(), displayName: "Shared", createdAt: .distantPast, isBuiltInDefault: false),
            BrowserProfileDefinition(id: UUID(), displayName: "shared", createdAt: .distantPast, isBuiltInDefault: false),
        ]
        let resolver = BrowserImportDestinationResolver()
        #expect(resolver.resolve(rawSelector: "SHARED", rawIdentifier: nil, createIfMissing: false, profiles: profiles) == .ambiguous(profiles))
        #expect(resolver.resolve(rawSelector: "Shared", rawIdentifier: profiles[0].id.uuidString, createIfMissing: false, profiles: profiles) == .matched(profiles[0].id))
        #expect(resolver.resolve(rawSelector: "new", rawIdentifier: nil, createIfMissing: true, profiles: profiles) == .create("new"))
    }
}
