import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextDaemon
import Foundation
import Testing

/// Browser profiles in the app (plans/cmux-next/data-model.md 5): the
/// profile a new tab gets is fixed on its record, the tab's engine store
/// follows that record, and profiles survive a relaunch.
@MainActor
struct BrowserProfileServiceTests {
    static let work = "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"

    /// One workspace, pane 3, with a frontend browser tab on surface 9 in
    /// browser profile `profile` (nil: no profile on the record).
    static func tree(profile: String?) throws -> DaemonTree {
        let profileField = profile.map { #","browser_profile_id":"\#($0)""# } ?? ""
        let tab = #"{"kind":"browser","name":"","surface":9,"dead":false,"browser_renderer":"frontend","browser_engine":"webkit","url":"https://example.com/"\#(profileField)}"#
        return try BrowserRecordMoveTests.tree(pane: 3, tab: tab)
    }

    static func scratch() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "browser-profiles-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func aNewTabStoresTheProfileTheCascadePicks() async throws {
        let services = ActionBindingCoverageTests.boundServices()
        services.daemon.store.apply(snapshot: try Self.tree(profile: nil))
        let profiles = services.browserProfiles
        try profiles.edit { try $0.create(id: Self.work, name: "Work", color: "green", icon: nil) }
        let workspace = try #require(services.daemon.store.workspaces.first)
        let browserTabs = try #require(services.cache.browserTabs)
        var stored: [String?] = []
        browserTabs.create = { _, _, _, profile, _ in
            stored.append(profile)
            return SurfaceID(rawValue: 9)
        }
        let pane = PaneID(rawValue: 3)
        let choice = BrowserEngineChoice(engine: .webkit)
        _ = try await browserTabs.open(choice, in: pane, url: "https://a.example/")
        try profiles.setWorkspaceDefault(Self.work, for: workspace.id)
        _ = try await browserTabs.open(choice, in: pane, url: "https://a.example/")
        _ = try await browserTabs.open(choice, in: pane, url: "https://a.example/", profile: "default")
        // An id with no record falls back to the workspace's profile.
        _ = try await browserTabs.open(choice, in: pane, url: "https://a.example/", profile: "11111111-1111-4111-8111-111111111111")
        // An incognito tab stores no profile: its window's session is its store.
        _ = try await browserTabs.open(choice, in: pane, url: "https://a.example/", incognito: true, profile: Self.work)
        #expect(stored == ["default", Self.work, "default", Self.work, nil])
        withExtendedLifetime(services) {}
    }

    @Test func aTabsStoreIsItsRecordsProfileAndChangingDefaultsDoesNotMoveIt() throws {
        let services = ActionBindingCoverageTests.boundServices()
        services.daemon.store.apply(snapshot: try Self.tree(profile: Self.work))
        let profiles = services.browserProfiles
        try profiles.edit { try $0.create(id: Self.work, name: "Work", color: nil, icon: nil) }
        let workspace = try #require(services.daemon.store.workspaces.first)
        let tab = try #require(workspace.screens.first?.panes.first?.tabs.first)
        let workStore = BrowserProfileID(rawValue: UUID(uuidString: Self.work)!)
        #expect(profiles.engineProfile(forTab: tab.id) == workStore)
        try profiles.setWorkspaceDefault("default", for: workspace.id)
        #expect(profiles.engineProfile(forTab: tab.id) == workStore)
        withExtendedLifetime(services) {}
    }

    @Test func aTabInAnotherProfileThanItsWorkspaceShowsADot() throws {
        let services = ActionBindingCoverageTests.boundServices()
        services.daemon.store.apply(snapshot: try Self.tree(profile: Self.work))
        let profiles = services.browserProfiles
        try profiles.edit { try $0.create(id: Self.work, name: "Work", color: "purple", icon: "💼") }
        let workspace = try #require(services.daemon.store.workspaces.first)
        let tab = try #require(workspace.screens.first?.panes.first?.tabs.first)
        #expect(profiles.tabBadge(for: tab, workspaceID: workspace.id)?.name == "Work")
        #expect(profiles.tabBadge(for: tab, workspaceID: workspace.id)?.color == .purple)
        try profiles.setWorkspaceDefault(Self.work, for: workspace.id)
        #expect(profiles.tabBadge(for: tab, workspaceID: workspace.id) == nil)
        // The omnibar names the profile once two exist.
        #expect(profiles.omnibarBadge(forTab: tab.id)?.monogram == "💼")
        withExtendedLifetime(services) {}
    }

    @Test func deletingAProfileClearsItsDefaultsAndItsTabsLeaveItsStore() async throws {
        let services = ActionBindingCoverageTests.boundServices()
        services.daemon.store.apply(snapshot: try Self.tree(profile: Self.work))
        let profiles = services.browserProfiles
        try profiles.edit { try $0.create(id: Self.work, name: "Work", color: nil, icon: nil) }
        let workspace = try #require(services.daemon.store.workspaces.first)
        let tab = try #require(workspace.screens.first?.panes.first?.tabs.first)
        try profiles.setWorkspaceDefault(Self.work, for: workspace.id)
        let browserTabs = try #require(services.cache.browserTabs)
        browserTabs.isAvailable = { true }
        var reopened: [(String, String?)] = []
        browserTabs.create = { _, url, _, profile, _ in
            reopened.append((url, profile))
            return SurfaceID(rawValue: 10)
        }
        #expect(throws: BrowserProfileBookError.defaultProfile) { try profiles.delete("default") }
        try profiles.delete(Self.work)
        #expect(profiles.record(Self.work) == nil)
        #expect(profiles.workspaceDefault(workspace.id) == nil)
        // A record still naming the deleted profile never reopens its store.
        #expect(profiles.engineProfile(forTab: tab.id) == .default)
        await BrowserTabTests.settle { !reopened.isEmpty }
        #expect(reopened.map(\.0) == ["https://example.com/"])
        #expect(reopened.map(\.1) == ["default"])
        withExtendedLifetime(services) {}
    }

    @Test func profilesSurviveARelaunch() async throws {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let services = ActionBindingCoverageTests.boundServices()
        let first = BrowserProfileService(services: services)
        first.load(directory: directory)
        await first.loaded()
        let made = try first.edit { try $0.create(name: "Client", color: "orange", icon: "🧪") }
        await first.flush()

        let second = BrowserProfileService(services: services)
        second.load(directory: directory)
        await second.loaded()
        #expect(second.book == first.book)
        #expect(second.record(made.id)?.name == "Client")
        withExtendedLifetime(services) {}
    }

    /// Coordinator decision 2026-09-30: with `browser-profiles-v1` the home
    /// daemon holds the records (after the one-time copy from the file).
    @Test func theHomeDaemonsRecordsWinOnceCopied() throws {
        let services = ActionBindingCoverageTests.boundServices()
        let identify = #"{"app":"cmux-tui","version":"0.1.0","protocol":12,"capabilities":["profiles-v1","browser-profiles-v1"],"session":"t","pid":1,"registry_id":"r","generation":"GEN","workspace_revision":0}"#
        _ = services.daemon.store.apply(.connected(try JSONDecoder().decode(DaemonIdentity.self, from: Data(identify.utf8)),
                                                   generationChanged: false))
        var tree = DaemonTree(registryID: "r", workspaceRevision: 1, workspaces: [])
        tree.personal = PersonalState(revision: 1)
        tree.personal?.browserProfiles = [BrowserProfileSnapshot(id: "default", name: "Default", index: 0),
                                          BrowserProfileSnapshot(id: Self.work, name: "Work", color: "green", index: 1)]
        services.daemon.store.apply(snapshot: tree)
        let profiles = services.browserProfiles
        try profiles.edit { try $0.create(name: "Local only", color: nil, icon: nil) }
        // Not copied yet: this Mac's file still answers.
        #expect(profiles.daemonServesRecords)
        #expect(profiles.ordered.map(\.name) == ["Default", "Local only"])
        try profiles.edit { $0.recordsMigrated = true }
        #expect(profiles.ordered.map(\.id) == ["default", Self.work])
        #expect(profiles.record(Self.work)?.color == "green")
        #expect(profiles.isKnown(Self.work))
        // Edits are validated here before they go to the daemon.
        #expect(throws: BrowserProfileBookError.unknownProfile) { try profiles.rename("11111111-1111-4111-8111-111111111111", to: "x") }
        #expect(throws: BrowserProfileBookError.invalidName) { try profiles.createProfileNow(name: " ", color: nil, icon: nil) }
        #expect(throws: BrowserProfileBookError.invalidColor) { try profiles.setColor(Self.work, "teal") }
        withExtendedLifetime(services) {}
    }

    @Test func browserProfileActionsAreBound() {
        let registry = ActionBindingCoverageTests.boundServices().registry
        let unbound = BrowserProfileActionIDs.all.filter { !registry.isBound($0) }
        #expect(unbound.isEmpty, "unbound: \(unbound)")
    }
}

enum BrowserProfileActionIDs {
    static let all: [ActionID] = ActionCatalog.all.map(\.id).filter { $0.rawValue.hasPrefix("browserProfile.") }
}
