import Foundation
import Testing
@testable import CmuxAgentJournal

@Suite("Alias resolver")
struct AgentJournalAliasResolverTests {
    @Test func resolvesChainsAndFailsClosedOnCycles() {
        let a = UUID().uuidString
        let b = UUID().uuidString
        let c = UUID().uuidString
        var resolver = AgentJournalAliasResolver(surfaces: [a: b])
        resolver.merge(workspaces: [:], surfaces: [b: c])
        #expect(resolver.resolvedSurfaceId(a) == c)
        #expect(resolver.resolvedSurfaceId(c) == c)
        let unknown = UUID().uuidString
        #expect(resolver.resolvedSurfaceId(unknown) == unknown)

        let cyclic = AgentJournalAliasResolver(surfaces: [a: b, b: a])
        #expect(cyclic.resolvedSurfaceId(a) == nil)
    }

    @Test func matchesStoreSemantics() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alias-resolver-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AgentJournalStore(
            databaseURL: directory.appendingPathComponent("journal.sqlite3")
        )
        defer { store.close() }
        let old = UUID().uuidString
        let new = UUID().uuidString
        try store.recordRestoreAliases(workspaceAliases: [old: new], surfaceAliases: [old: new])
        let maps = try store.aliasMaps()
        let resolver = AgentJournalAliasResolver(
            workspaces: maps.workspaces,
            surfaces: maps.surfaces
        )
        let storeWorkspace = try store.resolvedWorkspaceId(old)
        let storeSurface = try store.resolvedSurfaceId(old)
        #expect(resolver.resolvedWorkspaceId(old) == storeWorkspace)
        #expect(resolver.resolvedSurfaceId(old) == storeSurface)
    }
}
