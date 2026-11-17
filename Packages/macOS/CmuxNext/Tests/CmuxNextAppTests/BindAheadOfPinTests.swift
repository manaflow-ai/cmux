import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// App code can bind a catalog row before the pinned app FFI carries it: the Swift and the Rust row
/// land in one PR, and the release with the row is pinned an hour or more later. Until then the
/// Debug app must still launch (#40159's `cloud.team.*` binds trapped every Debug launch at
/// `CloudTeamFeature+Actions.swift:41` until the re-pin).
@MainActor
struct BindAheadOfPinTests {
    @Test func cloudTeamActionsBindIntoACatalogWithoutTheirRows() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let registry = ActionRegistry(catalog: [])

        services.cloudTeam.bind(into: registry, reason: { nil })

        #expect(registry.action(for: "cloud.team.sessions") == nil)
    }

    @Test func cloudHandlerBindsIntoACatalogWithoutItsRow() {
        let registry = ActionRegistry(catalog: [])

        CloudHandlers.bind("cloud.notInThePinnedCatalog", registry, reason: { nil }) { _ in }

        #expect(registry.action(for: "cloud.notInThePinnedCatalog") == nil)
    }

    @Test func unavailablePlaceholdersBindIntoACatalogWithoutTheirRows() {
        let registry = ActionRegistry(catalog: [])

        registry.bindUnavailable(["notInThePinnedCatalog"], ActionFailure(message: "unavailable"))

        #expect(registry.action(for: "notInThePinnedCatalog") == nil)
    }
}
