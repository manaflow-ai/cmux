import CmuxNextDaemon
import CmuxNextSidebar
import Foundation
import Observation
import Testing
@testable import CmuxNextApp

/// The app's mirror + intent log over `sidebar-layout-v1`
/// (plans/cmux-next/sidebar-sections.md 5, OWNERSHIP-PRINCIPLES "clients
/// are projections"): intents show at once and leave on their reply or
/// reject, a disconnect keeps them for a resend with the same key, the
/// mirror never moves back, and nothing is sent while the owner is away.
@MainActor @Suite struct SidebarLayoutServiceTests {
    /// An owner that holds each update until the test answers it.
    /// Observable like the daemon service, so the service follows it.
    @Observable @MainActor final class FakeOwner: SidebarLayoutRemote {
        var isAvailable = true
        var changeToken: UInt64 = 0
        @ObservationIgnored var stored = SidebarLayoutDocument.defaults
        @ObservationIgnored var calls: [(key: String, op: SidebarLayoutOp)] = []
        @ObservationIgnored private var waiting: [String: CheckedContinuation<SidebarLayoutDocument, any Error>] = [:]

        func get() async throws -> SidebarLayoutDocument { stored }

        func update(_ op: SidebarLayoutOp, key: String) async throws -> SidebarLayoutDocument {
            calls.append((key, op))
            return try await withCheckedThrowingContinuation { waiting[key] = $0 }
        }

        /// Applies the op like the store and answers.
        func accept(_ key: String) {
            guard let call = calls.last(where: { $0.key == key }), let continuation = waiting.removeValue(forKey: key) else { return }
            if case .success(let next) = SidebarLayoutReducer.reduce(stored, call.op) { stored = next }
            continuation.resume(returning: stored)
        }

        func fail(_ key: String, _ error: any Error) {
            waiting.removeValue(forKey: key)?.resume(throwing: error)
        }

        var isWaiting: Bool { !waiting.isEmpty }
    }

    private struct Rejected: Error {}

    /// A defaults domain of its own, so no test sees another's Recents offer.
    static func freshDefaults() -> UserDefaults {
        let name = "SidebarLayoutServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func settled(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
    }

    @Test func anIntentShowsAtOnceAndLeavesOnItsReply() async throws {
        let owner = FakeOwner()
        let service = SidebarLayoutService(remote: owner, prototypeEnabled: { false }, recentsOffered: Self.freshDefaults())
        try service.send(.itemRemove(LayoutItemID("itm_home")))
        #expect(service.document.firstItem(with: .app("cmux/home")) == nil)
        #expect(service.pending.count == 1)
        await settled { owner.isWaiting }
        owner.accept(try #require(owner.calls.first?.key))
        await settled { service.pending.isEmpty }
        #expect(service.mirror.revision == 1)
        #expect(service.document.firstItem(with: .app("cmux/home")) == nil)
    }

    @Test func aRejectAnimatesBackAndIsReported() async throws {
        let owner = FakeOwner()
        var refusals: [String] = []
        let service = SidebarLayoutService(remote: owner, onRefused: { refusals.append($0) }, prototypeEnabled: { false }, recentsOffered: Self.freshDefaults())
        try service.send(.itemRemove(LayoutItemID("itm_settings")))
        #expect(service.document.item(LayoutItemID("itm_settings")) == nil)
        await settled { owner.isWaiting }
        owner.fail(try #require(owner.calls.first?.key), Rejected())
        await settled { service.pending.isEmpty }
        #expect(service.document.item(LayoutItemID("itm_settings")) != nil)
        #expect(refusals.count == 1)
    }

    @Test func aLocalRejectIsRefusedWithoutSending() {
        let owner = FakeOwner()
        let service = SidebarLayoutService(remote: owner, prototypeEnabled: { false }, recentsOffered: Self.freshDefaults())
        #expect(throws: (any Error).self) { try service.send(.sectionRemove(SidebarLayoutDocument.workspacesSectionID)) }
        #expect(owner.calls.isEmpty && service.pending.isEmpty)
    }

    @Test func aDisconnectKeepsTheIntentAndResendsItWithTheSameKey() async throws {
        let owner = FakeOwner()
        let service = SidebarLayoutService(remote: owner, prototypeEnabled: { false }, recentsOffered: Self.freshDefaults())
        service.start()
        try service.send(.itemRemove(LayoutItemID("itm_home")))
        await settled { owner.isWaiting }
        let key = try #require(owner.calls.first?.key)
        owner.isAvailable = false
        owner.fail(key, DaemonError.connectionClosed(reason: "test"))
        await settled { service.pending.first?.inFlight == false }
        #expect(service.document.firstItem(with: .app("cmux/home")) == nil)
        #expect(throws: (any Error).self) { try service.send(.itemRemove(LayoutItemID("itm_settings"))) }
        owner.isAvailable = true
        await settled { owner.calls.count == 2 }
        #expect(owner.calls.map(\.key) == [key, key])
        owner.accept(key)
        await settled { service.pending.isEmpty }
        #expect(service.mirror.revision == 1)
    }

    @Test func theMirrorNeverMovesBackAndFollowsPersonalChanges() async throws {
        let owner = FakeOwner()
        let service = SidebarLayoutService(remote: owner, prototypeEnabled: { false }, recentsOffered: Self.freshDefaults())
        service.start()
        owner.stored = try SidebarLayoutReducer.reduce(.defaults, .itemRemove(LayoutItemID("itm_home"))).get()
        owner.changeToken += 1
        await settled { service.mirror.revision == 1 }
        #expect(service.document.firstItem(with: .app("cmux/home")) == nil)
        service.settle("stale", confirmed: .defaults)
        #expect(service.mirror.revision == 1)
    }

    /// A stored layout that still equals the window rail's default (removed
    /// by R52) is moved back to the sections default through the owner
    /// (ordinary intents, applied by its reducer), once; a customized
    /// layout is never touched.
    @Test func aStoredRailLayoutMigratesBackThroughTheOwner() async throws {
        let owner = FakeOwner()
        owner.stored = SidebarLayoutDocument(revision: 3, sections: SidebarLayoutDocument.railDefaults.sections)
        let service = SidebarLayoutService(remote: owner, prototypeEnabled: { false }, recentsOffered: Self.freshDefaults())
        service.start()
        let expected = owner.stored.layoutMigrationOps
        #expect(!expected.isEmpty)
        await settled { owner.calls.count == expected.count }
        #expect(owner.calls.map(\.op) == expected)
        #expect(service.document.sections == SectionsSidebarDefaultTests.migratedRail)
        for call in owner.calls { owner.accept(call.key) }
        await settled { service.pending.isEmpty }
        #expect(owner.stored.sections == SectionsSidebarDefaultTests.migratedRail)
        #expect(service.mirror.sections == SectionsSidebarDefaultTests.migratedRail)
        // A later fetch of the migrated layout sends nothing more.
        owner.changeToken += 1
        await settled { false }
        #expect(owner.calls.count == expected.count)
    }

    @Test func aCustomizedStoredLayoutIsNotMigrated() async throws {
        let owner = FakeOwner()
        owner.stored = try SidebarLayoutReducer.reduce(SidebarLayoutDocument.railDefaults, .itemRemove(LayoutItemID("itm_home"))).get()
        let service = SidebarLayoutService(remote: owner, prototypeEnabled: { false }, recentsOffered: Self.freshDefaults())
        service.start()
        await settled { service.mirror.revision == 1 }
        await settled { false }
        // Customized: only its built-in App Store becomes an app item (R63/R64).
        let expected = owner.stored.appRefMigrationOps
        #expect(owner.calls.map(\.op) == expected)
    }

    /// A stored default from before Recents gains it once per Mac; after
    /// the user removes it, a later launch leaves it out.
    @Test func recentsIsOfferedOncePerMac() async throws {
        let defaults = Self.freshDefaults()
        let owner = FakeOwner()
        owner.stored.sections.removeAll { $0.id == SidebarLayoutDocument.recentsSectionID }
        let first = SidebarLayoutService(remote: owner, prototypeEnabled: { false }, recentsOffered: defaults)
        first.start()
        await settled { owner.calls.count == 1 }
        #expect(owner.calls.map(\.op) == [.sectionAdd(SidebarLayoutDocument.recentsSection, index: 1)])
        let next = SidebarLayoutService(remote: owner, prototypeEnabled: { false }, recentsOffered: defaults)
        next.start()
        await settled { next.mirror.sections == owner.stored.sections }
        await settled { false }
        #expect(owner.calls.count == 1)
    }

    @Test func snapshotsDecodeTheDecimalRevision() throws {
        let doc = try SidebarLayoutReducer.reduce(.defaults, .itemRemove(LayoutItemID("itm_home"))).get()
        var json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(doc))
        if case .object(var object) = json {
            object["revision"] = .string("1")
            json = .object(object)
        }
        #expect(try DaemonSidebarLayoutRemote.document(json) == doc)
    }
}
