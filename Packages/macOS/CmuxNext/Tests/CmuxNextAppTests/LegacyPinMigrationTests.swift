import CmuxNextSidebar
import Foundation
import Observation
import Testing
@testable import CmuxNextApp

/// The one-time move of legacy pinned workspaces into tiles
/// (PINNED-ITEMS-END-TO-END step 3 item 6): lossless, idempotent, marked
/// done per Mac and session only after the owner's layout shows the pins.
@MainActor @Suite struct LegacyPinMigrationTests {
    /// An owner that applies each op at once and signals the change.
    @Observable @MainActor final class Owner: SidebarLayoutRemote {
        var isAvailable = true
        var changeToken: UInt64 = 0
        var legacyPins: [LegacyPins] = []
        @ObservationIgnored var stored = SidebarLayoutDocument.defaults
        @ObservationIgnored var updates: [SidebarLayoutOp] = []
        /// Refuse every update (a permanent reject).
        @ObservationIgnored var refuses = false

        func get() async throws -> SidebarLayoutDocument { stored }

        func update(_ op: SidebarLayoutOp, key: String) async throws -> SidebarLayoutDocument {
            updates.append(op)
            if refuses { throw CancellationError() }
            stored = try SidebarLayoutReducer.reduce(stored, op).get()
            changeToken += 1
            return stored
        }
    }

    static let session = "44444444-5555-4666-8777-888888888888"
    static let alpha = LayoutItemRef.workspace("\(session):ws_alpha")
    static let beta = LayoutItemRef.workspace("\(session):ws_beta")

    private func settled(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1000 where !condition() { await Task.yield() }
    }

    private func service(_ owner: Owner, defaults: UserDefaults = SidebarLayoutServiceTests.freshDefaults()) -> SidebarLayoutService {
        let service = SidebarLayoutService(remote: owner, prototypeEnabled: { false }, recentsOffered: defaults)
        service.start()
        return service
    }

    @Test func legacyPinsBecomeTilesAndTheSessionIsMarkedAfterTheOwnerConfirms() async throws {
        let owner = Owner()
        owner.legacyPins = [LegacyPins(session: Self.session, refs: [Self.alpha, Self.beta])]
        let service = service(owner)
        await settled { service.legacyPinsMigrated.contains(Self.session) }
        #expect(owner.stored.section(SidebarLayoutDocument.pinnedSectionID)?.items.map(\.ref) == [Self.alpha, Self.beta])
        #expect(service.legacyPinsMigrated == [Self.session])
        #expect(owner.updates.count == 2, "one op per workspace")
        #expect(SidebarLayoutDocument.defaults.sections.allSatisfy { section in
            section.items.allSatisfy { owner.stored.item($0.id) != nil }
        }, "nothing is removed")
    }

    @Test func aDoneSessionIsNeverMovedAgainOnThisMac() async throws {
        let defaults = SidebarLayoutServiceTests.freshDefaults()
        defaults.set([Self.session], forKey: SidebarLayoutService.legacyPinsMigratedKey)
        let owner = Owner()
        owner.legacyPins = [LegacyPins(session: Self.session, refs: [Self.alpha])]
        let service = service(owner, defaults: defaults)
        await settled { service.mirror.revision > 0 || owner.updates.count > 0 }
        for _ in 0..<200 { await Task.yield() }
        #expect(owner.updates.isEmpty, "the user may have unpinned it since")
    }

    @Test func pinsAlreadyOnTopAreMarkedWithoutAnOp() async throws {
        let owner = Owner()
        owner.stored = try SidebarLayoutReducer.reduce(owner.stored, try #require(owner.stored.addToTopOp(Self.alpha))).get()
        owner.legacyPins = [LegacyPins(session: Self.session, refs: [Self.alpha])]
        let service = service(owner)
        await settled { service.legacyPinsMigrated.contains(Self.session) }
        #expect(owner.updates.isEmpty)
    }

    @Test func aRefusedMoveIsNotMarkedAndNotRetriedInALoop() async throws {
        let owner = Owner()
        owner.refuses = true
        owner.legacyPins = [LegacyPins(session: Self.session, refs: [Self.alpha])]
        let service = service(owner)
        await settled { !owner.updates.isEmpty && service.pending.isEmpty }
        owner.changeToken += 1
        for _ in 0..<300 { await Task.yield() }
        #expect(owner.updates.count == 1)
        #expect(service.legacyPinsMigrated.isEmpty)
    }

    @Test func aSessionTreeThatLoadsLaterIsMoved() async throws {
        let owner = Owner()
        let service = service(owner)
        await settled { service.mirror == owner.stored && owner.changeToken == 0 }
        for _ in 0..<100 { await Task.yield() }
        owner.legacyPins = [LegacyPins(session: Self.session, refs: [Self.alpha])]
        await settled { service.legacyPinsMigrated.contains(Self.session) }
        #expect(owner.stored.isPinned(Self.alpha))
    }
}
