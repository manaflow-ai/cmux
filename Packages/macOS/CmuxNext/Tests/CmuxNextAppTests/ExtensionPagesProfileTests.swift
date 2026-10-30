import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextDaemon
import Foundation
import Testing

/// Manage Extensions and Open Chrome Web Store open their page in the browser profile they were
/// asked for, as Chrome does: the profile of the tab whose menu ran them, or the profile the
/// palette or profile menu named. User report (2026-10-21): "I can't install Bitwarden on the
/// other browser profile": from a tab of a second profile both pages opened in the default
/// profile, so the Web Store installed there (and showed Bitwarden as already added).
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ExtensionPagesProfileTests {
    private static func browserTabs(_ services: AppServices, pane: String) -> [TabModel] {
        services.daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).filter { $0.id == pane }.flatMap(\.tabs).filter { $0.kind == .browser }
    }

    /// A second profile and a selected browser tab of it in the first pane.
    private static func secondProfileTab(_ services: AppServices, _ connection: DaemonConnection) async throws -> (profile: String, pane: String, tab: TabModel) {
        // The extension pages are Chromium tabs; the record is what this checks, so no Chromium runs here.
        services.cache.browserTabs.cefUnavailable = { nil }
        let profiles = services.browserProfiles
        let name = "Second \(UUID().uuidString.prefix(6))"
        let id = try await profiles.createProfile(name: name, color: nil, icon: nil)
        try await PinnedPageTests.until({ profiles.isKnown(id) }, report: { "profiles \(profiles.ordered.map(\.id))" })
        // A fresh state has not moved its records to the daemon yet: the daemon gets the same
        // profile too, as a migrated install has it, so it opens tabs of it.
        if !profiles.usesDaemonRecords {
            _ = try await connection.createBrowserProfile(CreateBrowserProfileRequest(id: id, name: name))
        }
        let pane = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first)
        let surface = try await connection.newFrontendBrowserTab(url: "https://example.com/", engine: .webkit, in: pane.handle,
                                                                profileID: id, activate: true).surface
        try await PinnedPageTests.until({ services.daemon.store.tab(surface: surface) != nil },
                                        report: { WindowStateReport.describe(services, surface: surface) })
        let tab = try #require(services.daemon.store.tab(surface: surface))
        #expect(profiles.profileID(ofTab: tab) == id)
        return (id, pane.id, tab)
    }

    private static func opensInProfile(_ action: ActionID, invocation: ActionInvocation, expected: String,
                                       pane: String, services: AppServices) async throws {
        let before = Set(browserTabs(services, pane: pane).map(\.id))
        var ran = false
        let refusal = services.registry.capturingRefusal { ran = services.registry.perform(action, invocation: invocation) }
        #expect(ran, "\(action) did not run: \(refusal ?? "")")
        try await PinnedPageTests.until({ browserTabs(services, pane: pane).contains { !before.contains($0.id) } }, within: .seconds(30),
                                        report: { "refusal \(refusal ?? "none"); " + WindowStateReport.describe(services, page: nil) })
        let made = try #require(browserTabs(services, pane: pane).first { !before.contains($0.id) })
        #expect(services.browserProfiles.profileID(ofTab: made) == expected,
                "\(action) opened its page in profile \(services.browserProfiles.profileID(ofTab: made)), not \(expected)")
    }

    @Test(arguments: ["browser.extensions.manage", "browser.extensions.webStore"] as [ActionID])
    func extensionPagesOpenInTheProfileOfTheTabThatAsked(action: ActionID) async throws {
        try await PinnedPageTests.withApp { services, connection in
            let (profile, pane, tab) = try await Self.secondProfileTab(services, connection)
            let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab.id), origin: .user)
            try await Self.opensInProfile(action, invocation: invocation, expected: profile, pane: pane, services: services)
        }
    }

    @Test(arguments: ["browser.extensions.manage", "browser.extensions.webStore"] as [ActionID])
    func extensionPagesOpenInTheProfileTheyAreGiven(action: ActionID) async throws {
        try await PinnedPageTests.withApp { services, connection in
            let (profile, pane, _) = try await Self.secondProfileTab(services, connection)
            // A default-profile tab asks for the second profile's page (the profile menu's row, the palette's pick).
            let paneHandle = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first?.handle)
            let surface = try await connection.newFrontendBrowserTab(url: "https://example.org/", engine: .webkit, in: paneHandle,
                                                                    profileID: BrowserProfileRecord.defaultID, activate: true).surface
            try await PinnedPageTests.until({ services.daemon.store.tab(surface: surface) != nil },
                                            report: { WindowStateReport.describe(services, surface: surface) })
            let asking = try #require(services.daemon.store.tab(surface: surface))
            let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: asking.id),
                                              arguments: ["browserProfile": .string(profile)], origin: .user)
            try await Self.opensInProfile(action, invocation: invocation, expected: profile, pane: pane, services: services)
        }
    }
}
