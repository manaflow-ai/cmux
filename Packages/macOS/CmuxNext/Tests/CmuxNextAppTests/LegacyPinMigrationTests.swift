import CmuxNextSidebar
import Foundation
import Observation
import Testing
@testable import CmuxNextApp

/// The one-time move of legacy pinned workspaces into tiles
/// (PINNED-ITEMS-END-TO-END step 3 item 6): lossless, idempotent, labeled
/// with the workspace's name; the done mark is the cleared legacy flag in
/// the session's own store, set only after the owner's layout shows the
/// pins, so a second Mac of the session does not pin again.
@MainActor @Suite struct LegacyPinMigrationTests {
    /// An owner that applies each op at once and signals the change; its
    /// sessions' legacy flags are `legacyPins` (shared by every Mac).
    @Observable @MainActor final class Owner: SidebarLayoutRemote {
        var isAvailable = true
        var changeToken: UInt64 = 0
        var legacyPins: [LegacyPins] = []
        @ObservationIgnored var stored = SidebarLayoutDocument.defaults
        @ObservationIgnored var updates: [SidebarLayoutOp] = []
        @ObservationIgnored var cleared: [LayoutItemRef] = []
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

        func clearLegacyPins(_ refs: [LayoutItemRef]) {
            cleared += refs
            legacyPins = legacyPins.compactMap { group in
                var group = group
                group.refs.removeAll { refs.contains($0) }
                return group.refs.isEmpty ? nil : group
            }
        }
    }

    static let session = "44444444-5555-4666-8777-888888888888"
    static let alpha = LayoutItemRef.workspace("\(session):ws_alpha")
    static let beta = LayoutItemRef.workspace("\(session):ws_beta")
    static let pins = LegacyPins(session: session, refs: [alpha, beta], labels: [alpha: "Alpha", beta: "Beta"])

    private func settled(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1000 where !condition() { await Task.yield() }
    }

    private func service(_ owner: Owner) -> SidebarLayoutService {
        let service = SidebarLayoutService(remote: owner, prototypeEnabled: { false }, recentsOffered: SidebarLayoutServiceTests.freshDefaults())
        service.start()
        return service
    }

    @Test func legacyPinsBecomeLabeledTilesAndTheFlagsClearAfterTheOwnerConfirms() async throws {
        let owner = Owner()
        owner.legacyPins = [Self.pins]
        let service = service(owner)
        await settled { owner.cleared.count == 2 }
        let tiles = try #require(owner.stored.section(SidebarLayoutDocument.pinnedSectionID)?.items)
        #expect(tiles.map(\.ref) == [Self.alpha, Self.beta])
        #expect(tiles.map(\.label) == ["Alpha", "Beta"], "a closed workspace's tile keeps its name")
        #expect(owner.cleared == [Self.alpha, Self.beta])
        #expect(owner.updates.count == 2, "one op per workspace")
        #expect(SidebarLayoutDocument.defaults.sections.allSatisfy { section in
            section.items.allSatisfy { owner.stored.item($0.id) != nil }
        }, "nothing is removed")
        _ = service
    }

    @Test func aSecondMacDoesNotPinAgainWhatTheUserUnpinned() async throws {
        let owner = Owner()
        owner.legacyPins = [Self.pins]
        let first = service(owner)
        await settled { owner.cleared.count == 2 }
        let tile = try #require(owner.stored.section(SidebarLayoutDocument.pinnedSectionID)?.items.first)
        owner.stored = try SidebarLayoutReducer.reduce(owner.stored, .itemRemove(tile.id)).get()
        owner.changeToken += 1
        let updates = owner.updates.count
        let second = service(owner)
        await settled { second.mirror == owner.stored }
        for _ in 0..<300 { await Task.yield() }
        #expect(owner.updates.count == updates, "the done mark is in the session's store, not on one Mac")
        #expect(!owner.stored.isPinned(Self.alpha))
        _ = first
    }

    @Test func pinsAlreadyOnTopClearTheirFlagsWithoutAnOp() async throws {
        let owner = Owner()
        owner.stored = try SidebarLayoutReducer.reduce(owner.stored, try #require(owner.stored.addToTopOp(Self.alpha))).get()
        owner.legacyPins = [LegacyPins(session: Self.session, refs: [Self.alpha])]
        let service = service(owner)
        await settled { !owner.cleared.isEmpty }
        #expect(owner.updates.isEmpty)
        #expect(owner.cleared == [Self.alpha])
        _ = service
    }

    @Test func aRefusedMoveKeepsTheFlagAndIsNotRetriedInALoop() async throws {
        let owner = Owner()
        owner.refuses = true
        owner.legacyPins = [LegacyPins(session: Self.session, refs: [Self.alpha])]
        let service = service(owner)
        await settled { !owner.updates.isEmpty && service.pending.isEmpty }
        owner.changeToken += 1
        for _ in 0..<300 { await Task.yield() }
        #expect(owner.updates.count == 1)
        #expect(owner.cleared.isEmpty, "no flag is cleared before its tile is confirmed")
    }

    @Test func aSessionTreeThatLoadsLaterIsMoved() async throws {
        let owner = Owner()
        let service = service(owner)
        await settled { service.mirror == owner.stored && owner.changeToken == 0 }
        for _ in 0..<100 { await Task.yield() }
        owner.legacyPins = [LegacyPins(session: Self.session, refs: [Self.alpha])]
        await settled { !owner.cleared.isEmpty }
        #expect(owner.stored.isPinned(Self.alpha))
    }
}
