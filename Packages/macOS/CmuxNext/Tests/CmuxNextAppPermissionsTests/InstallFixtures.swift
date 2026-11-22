@testable import CmuxNextAppPermissions
import Foundation

/// Random ops and actors for the install-state properties.
enum InstallFixtures {
    static let apps = ["cmux/search", "cmux/inbox", "acme/board", "acme/team-tool", "kestrel/snippets"]
    static let teamApp = "acme/team-tool"
    static let clients = ["mac", "phone", "cli"]

    static func kind(_ rng: inout SeededRandom) -> AppStateOp.Kind {
        switch rng.next() % 10 {
        case 0: .install(AppInstallSource.allCases.randomElement(using: &rng) ?? .user)
        case 1: .remove(confirmed: rng.next() % 2 == 0)
        case 2: .enable
        case 3: .disable
        case 4, 5: .hide
        case 6, 7: .unhide
        default: .setHiddenAccess(cli: maybeBool(&rng), mcp: maybeBool(&rng), automations: maybeBool(&rng))
        }
    }

    static func maybeBool(_ rng: inout SeededRandom) -> Bool? {
        switch rng.next() % 3 {
        case 0: nil
        case 1: true
        default: false
        }
    }

    static func actor(_ rng: inout SeededRandom) -> AppStateActor {
        // Mostly the user, so the store reaches interesting states.
        let origin: AppStateOrigin = rng.next() % 3 == 0 ? (AppStateOrigin.allCases.randomElement(using: &rng) ?? .user) : .user
        return AppStateActor(client: clients.randomElement(using: &rng) ?? "mac", origin: origin, teamAdmin: rng.next() % 4 == 0)
    }

    static func op(_ rng: inout SeededRandom, key: String) -> AppStateOp {
        AppStateOp(key: key, app: apps.randomElement(using: &rng) ?? apps[0], kind: kind(&rng))
    }

    static let catalog = [AppCatalogEntry(appID: "cmux/search", tier: .firstParty), AppCatalogEntry(appID: "cmux/inbox", tier: .firstParty)]

    /// A store reached through the reducer: default installs, a team
    /// install, then random ops (with a bootstrap now and then).
    static func store(_ rng: inout SeededRandom, steps: Int = 25) -> AppStateStore {
        var store = AppDefaultInstalls.bootstrap(AppStateStore(), catalog: catalog).0
        let admin = AppStateActor(client: "admin", origin: .user, teamAdmin: true)
        if case .success(let (next, _)) = AppStateReducer.apply(AppStateOp(key: "team", app: teamApp, kind: .install(.team)),
                                                                to: store, actor: admin) {
            store = next
        }
        for step in 0..<steps {
            if rng.next() % 8 == 0 {
                store = AppDefaultInstalls.bootstrap(store, catalog: catalog).0
                continue
            }
            if case .success(let (next, _)) = AppStateReducer.apply(op(&rng, key: "s\(step)"), to: store, actor: actor(&rng)) { store = next }
        }
        return store
    }
}
