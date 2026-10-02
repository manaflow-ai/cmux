@testable import CmuxNextAppPermissions
import Foundation
import Testing

@Suite struct AppPresenceFilterTests {
    /// A section, a menu-bar status item, a titlebar status item, an
    /// editor, a feed source, an fs provider and a palette op.
    private func items() -> [AppPresenceItem] {
        [.implementation("acme/board", "list", interface: "cmux.section/1"),
         .implementation("acme/board", "count", interface: "cmux.status/1", placement: "menuBar"),
         .implementation("acme/board", "chip", interface: "cmux.status/1"),
         .implementation("acme/board", "edit", interface: "cmux.editor/1"),
         .implementation("acme/board", "feed", interface: "cmux.feed.source/1"),
         .implementation("acme/board", "files", interface: "cmux.fs.provider/1"),
         .operation("acme/board", "board.refresh", surfaces: [.palette, .menus])]
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
    }

    @Test(arguments: [AppHiddenAccess.all, .noChannels, AppHiddenAccess(cli: true, mcp: false, automations: true)])
    func hiddenAppContributesNothingYetRunsThroughAllowedChannels(access: AppHiddenAccess) {
        let items = items()
        let states = state(hidden: true, access: access)
        for surface in AppUserSurface.allCases {
            #expect(AppPresenceFilter.visible(items, states: states, on: surface).isEmpty, "\(surface)")
        }
        #expect(AppPresenceFilter.absentApps(states) == ["acme/board"])
        #expect(AppPresenceFilter.run("acme/board", origin: .user, states: states).rejected == .hidden)
        let channels: [(AppRunOrigin, Bool)] = [(.cli, access.cli), (.mcp, access.mcp), (.automation, access.automations)]
        for (origin, allowed) in channels {
            let result = AppPresenceFilter.run("acme/board", origin: origin, states: states)
            #expect(allowed ? result.rejected == nil : result.rejected?.code == "app.hidden", "\(origin)")
        }
    }

    @Test func disabledOverridesEverything() {
        let states = state(hidden: Bool.random(), enabled: false)
        for surface in AppUserSurface.allCases {
            #expect(AppPresenceFilter.visible(items(), states: states, on: surface).isEmpty)
        }
        for origin in AppRunOrigin.allCases {
            #expect(AppPresenceFilter.run("acme/board", origin: origin, states: states).rejected == .disabled)
        }
        #expect(AppPresenceFilter.run("acme/other", origin: .cli, states: states).rejected?.code == "app.not_installed")
    }

    @Test(arguments: Array(UInt64(0)..<100))
    func reachableStatesFilterConsistently(seed: UInt64) {
        var rng = SeededRandom(seed: seed)
        let store = InstallFixtures.store(&rng)
        let items = InstallFixtures.apps.flatMap { app in
            [AppPresenceItem.implementation(app, "s", interface: "cmux.section/1"),
             .operation(app, "c", surfaces: [.palette]),
             .implementation(app, "m", interface: "cmux.status/1", placement: "menuBar")]
        }
        for surface in AppUserSurface.allCases {
            for item in AppPresenceFilter.visible(items, states: store.apps, on: surface) {
                let s = store.state(item.appID)
                #expect(s.installed && s.enabled && !s.hidden)
            }
        }
        for app in InstallFixtures.apps {
            let s = store.state(app)
            let userRun = AppPresenceFilter.run(app, origin: .user, states: store.apps).rejected == nil
            #expect(userRun == AppPresenceFilter.isPresent(s))
        }
    }
}
