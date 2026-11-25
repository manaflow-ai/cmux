import Foundation
import Testing
@testable import CmuxMobileModel

@MainActor @Suite struct AgentCatalogCacheTests {
    @Test func anEmptyCatalogIsStillAValidCachedAnswer() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "agent-catalog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AgentCatalogCache(directory: directory, accountID: { "account-one" })

        cache.save(.empty, for: "mac-one")
        cache.flush()

        #expect(cache.load(macID: "mac-one") == .empty)
    }

    @Test func catalogsAreScopedToTheSignedInAccount() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "agent-catalog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let one = AgentCatalogCache(directory: directory, accountID: { "account-one" })
        let two = AgentCatalogCache(directory: directory, accountID: { "account-two" })
        let catalog = AgentCatalog(harnesses: [AgentHarnessChoice(id: "claude", name: "Claude", family: "claude")])

        one.save(catalog, for: "mac-one")
        one.flush()

        #expect(one.load(macID: "mac-one") == catalog)
        #expect(two.load(macID: "mac-one") == nil)
    }
}
