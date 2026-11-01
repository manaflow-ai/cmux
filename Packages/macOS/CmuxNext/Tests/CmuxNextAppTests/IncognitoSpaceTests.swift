import AppKit
import CmuxNextActions
import CmuxNextMobile
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// Incognito spaces (Lawrence 14223, plans/cmux-next/spaces-overhaul-DESIGN.md rule 2): New Incognito
/// Space opens a new space in a new incognito window; nothing of it is kept: the space is deleted once its
/// window is gone (and at quit, and at the next launch after a crash, through the incognito ledger).
@MainActor @Suite(.serialized)
struct IncognitoSpaceTests {
    static func services() -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.windows.ordersWindowsIn = false
        return services
    }

    @Test func anIncognitoSpacesWindowIsIncognitoAndShowsTheSpace() {
        let services = Self.services()
        let space = ProfileID(rawValue: "prof_incognito")
        let window = services.windows.newIncognitoWindow(space: space)
        #expect(services.windows.isIncognito(window: window))
        #expect(services.windows.state(for: window).profileID == space)
        #expect(services.windows.incognitoSpaces[window] == space)
    }

    /// The window never opened (or closed): the space ends with it; a window still waiting keeps its space.
    @Test func theSpaceEndsWithItsWindow() {
        let services = Self.services()
        let space = ProfileID(rawValue: "prof_incognito")
        let window = services.windows.newIncognitoWindow(space: space)
        services.windows.endIncognitoSpacesIfUnused()
        #expect(services.windows.incognitoSpaces[window] == space, "a window still being created lost its space")
        services.windows.pendingClaims = services.windows.pendingClaims.filter { $0.value != window }
        services.windows.pendingEphemeralWindows.removeAll { $0 == window }
        services.windows.endIncognitoSpacesIfUnused()
        #expect(services.windows.incognitoSpaces[window] == nil)
    }

    /// Phones never see an incognito window's workspace (spaces-incognito-audit leak 3): the app hands the phone
    /// gate every incognito workspace it knows, a claimed one still being created included.
    @Test func phonesAreToldToHideIncognitoWorkspaces() throws {
        let services = Self.services()
        let window = services.windows.newIncognitoWindow(space: ProfileID(rawValue: "prof_incognito"))
        let key = try #require(services.windows.pendingClaims.first { $0.value == window }?.key)
        services.windows.recordIncognitoWorkspaces()
        #expect(services.mobile.access.hidesWorkspace(key), "a phone could list the incognito window's workspace")
        #expect(!services.mobile.access.hidesWorkspace(UUID().uuidString.lowercased()))
    }

    /// A new incognito window's workspace is hidden from phones as it is claimed, before the daemon creates it,
    /// not at the next membership sync: the phone's own daemon connection could list it in between.
    @Test func phonesHideANewIncognitoWorkspaceFromItsClaim() throws {
        let services = Self.services()
        let window = services.windows.newIncognitoWindow()
        let key = try #require(services.windows.pendingClaims.first { $0.value == window }?.key)
        #expect(services.mobile.access.hidesWorkspace(key), "a phone could list the incognito workspace while it was created")
    }

    /// Issue #31039: a workspace's tree entry can arrive before its ephemeral flag (`session.events`), so
    /// reconcile already placed it in a normal window when the flag lands. Phones hide it as the flag lands.
    @Test func phonesHideAWorkspaceWhoseEphemeralFlagLandsAfterItsPlacement() async throws {
        let services = Self.services()
        let key = UUID().uuidString.lowercased()
        services.daemon.store.apply(snapshot: DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: key), name: "workspace-1"),
        ]))
        _ = services.windows.registry.apply { $0.openWindow(id: "w-normal", workspaceIDs: [key]) }
        services.windows.observeMembership()
        defer { services.windows.membershipObservation?.cancel() }
        services.windows.recordIncognitoWorkspaces()
        #expect(!services.mobile.access.hidesWorkspace(key))
        try #require(services.daemon.store.workspace(id: key)).applyState(ephemeral: true, status: nil, screenGroups: nil)
        for _ in 0..<1_000 where !services.mobile.access.hidesWorkspace(key) { await Task.yield() }
        #expect(services.mobile.access.hidesWorkspace(key), "a phone could list a workspace whose ephemeral flag landed after its placement")
    }

    /// A crashed run's incognito workspaces are hidden from phones as the restore marks them, before they close.
    @Test func phonesHideACrashedRunsIncognitoWorkspacesAtOnce() {
        let services = Self.services()
        let leftover = UUID().uuidString.lowercased()
        IncognitoLeftovers.discard([leftover], services.windows)
        #expect(services.mobile.access.hidesWorkspace(leftover), "a phone could list a crashed run's incognito workspace")
    }

    /// The ledger keeps the incognito spaces, so a crashed run's are deleted at the next launch.
    @Test func theLedgerKeepsTheIncognitoSpaces() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "incognito-space-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = IncognitoWorkspaceLedger(url: directory.appending(path: "incognito-workspaces.json"))
        await ledger.record([], spaces: ["prof_a"])?.value
        #expect(ledger.hasLeftovers)
        #expect(await ledger.loadSpaces() == ["prof_a"])
        #expect(await ledger.load().isEmpty)
        // The space deleted: the file goes.
        await ledger.record([], spaces: [])?.value
        #expect(!ledger.hasLeftovers)
    }
}
