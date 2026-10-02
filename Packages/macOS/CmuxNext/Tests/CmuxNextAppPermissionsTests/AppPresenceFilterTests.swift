@testable import CmuxNextAppPermissions
import Foundation
import Testing

@Suite struct AppPresenceFilterTests {
    /// A section, a menu-bar status item, a titlebar status item, an
    /// editor, a feed source, an fs provider and a palette op.
    private func items(_ app: String = "acme/board") -> [AppPresenceItem] {
        [.implementation(app, "list", interface: "cmux.section/1"),
         .implementation(app, "count", interface: "cmux.status/1", placement: "menuBar"),
         .implementation(app, "chip", interface: "cmux.status/1"),
         .implementation(app, "edit", interface: "cmux.editor/1"),
         .implementation(app, "feed", interface: "cmux.feed.source/1"),
         .implementation(app, "files", interface: "cmux.fs.provider/1"),
         .operation(app, "board.refresh", surfaces: [.palette, .menus])]
    }

    private func state(hidden: Bool = false, enabled: Bool = true, access: AppHiddenAccess = .all) -> [String: AppInstallState] {
        ["acme/board": AppInstallState(appID: "acme/board", source: .user, enabled: enabled, hidden: hidden, hiddenAccess: access, revision: 3)]
    }

    @Test func visibleAppAppearsOnItsSurfaces() {
        let items = items()
        #expect(AppPresenceFilter.visible(items, states: state(), on: .sidebar).map(\.itemID) == ["list"])
        #expect(Set(AppPresenceFilter.visible(items, states: state(), on: .palette).map(\.itemID)) == ["list", "board.refresh"])
        #expect(AppPresenceFilter.visible(items, states: state(), on: .openWith).map(\.itemID) == ["edit"])
        #expect(AppPresenceFilter.visible(items, states: state(), on: .feeds).map(\.itemID) == ["feed"])
        #expect(AppPresenceFilter.visible(items, states: state(), on: .menuBar).map(\.itemID) == ["count"])
        #expect(AppPresenceFilter.visible(items, states: state(), on: .titlebar).map(\.itemID) == ["chip"])
        #expect(!AppPresenceFilter.visible(items, states: state(), on: .storeBadges).map(\.itemID).isEmpty)
    }

    @Test(arguments: [AppHiddenAccess.all, .noChannels, AppHiddenAccess(cli: true, mcp: false, automations: true)])
    func hiddenAppContributesNothingYetRunsThroughAllowedChannels(access: AppHiddenAccess) {
        let items = items()
        let states = state(hidden: true, access: access)
        for surface in AppUserSurface.allCases {
            #expect(AppPresenceFilter.visible(items, states: states, on: surface).isEmpty, "\(surface)")
        }
        #expect(AppPresenceFilter.presentApps(states).isEmpty)
        for origin in [AppRunOrigin.user, .remote] {
            #expect(AppPresenceFilter.run("acme/board", origin: origin, states: states).rejected == .hidden)
        }
        let channels: [(AppRunOrigin, Bool)] = [(.cli, access.cli), (.mcp, access.mcp), (.script, access.automations)]
        for (origin, allowed) in channels {
            let result = AppPresenceFilter.run("acme/board", origin: origin, states: states)
            #expect(allowed ? result.rejected == nil : result.rejected?.code == "app.hidden", "\(origin)")
        }
    }

    @Test(arguments: [false, true])
    func disabledOverridesEverything(hidden: Bool) {
        let states = state(hidden: hidden, enabled: false)
        for surface in AppUserSurface.allCases {
            #expect(AppPresenceFilter.visible(items(), states: states, on: surface).isEmpty)
        }
        for origin in AppRunOrigin.allCases {
            #expect(AppPresenceFilter.run("acme/board", origin: origin, states: states).rejected == .disabled)
        }
        #expect(AppPresenceFilter.run("acme/other", origin: .cli, states: states).rejected?.code == "app.not_installed")
    }

    @Test func appsWithoutARecordAreNotPresent() {
        // An allowlist: a catalog app nobody installed is absent.
        #expect(AppPresenceFilter.presentApps(state()) == ["acme/board"])
        #expect(AppPresenceFilter.visible(items("acme/never-installed"), states: state(), on: .sidebar).isEmpty)
    }

    /// The full visible set equals an independent predicate: present apps
    /// (installed, enabled, not hidden) times the interface table.
    @Test(arguments: Array(UInt64(0)..<100))
    func reachableStatesFilterLikeTheTable(seed: UInt64) {
        var rng = SeededRandom(seed: seed)
        let store = InstallFixtures.store(&rng)
        let all = (InstallFixtures.apps + ["acme/never-installed"]).flatMap { items($0) }
        let table: [String: Set<AppUserSurface>] = [
            "list": [.sidebar, .palette, .menus, .storeBadges], "count": [.menuBar, .storeBadges], "chip": [.titlebar, .storeBadges],
            "edit": [.openWith, .menus, .storeBadges], "feed": [.feeds, .storeBadges], "files": [.storeBadges],
            "board.refresh": [.palette, .menus, .storeBadges],
        ]
        for surface in AppUserSurface.allCases {
            let expected = Set(all.filter { item in
                let s = store.apps[item.appID]
                return s?.source != nil && s?.enabled == true && s?.hidden == false && table[item.itemID, default: []].contains(surface)
            }.map(\.id))
            #expect(Set(AppPresenceFilter.visible(all, states: store.apps, on: surface).map(\.id)) == expected, "\(surface)")
        }
        for app in InstallFixtures.apps {
            let userRun = AppPresenceFilter.run(app, origin: .user, states: store.apps).rejected == nil
            #expect(userRun == AppPresenceFilter.presentApps(store.apps).contains(app))
        }
    }
}
