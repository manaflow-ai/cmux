@testable import CmuxNextAppPermissions
import Foundation

/// Random ops and actors for the install-state properties.
enum InstallFixtures {
    static let apps = ["cmux/search", "cmux/inbox", "acme/board", "acme/team-tool", "kestrel/snippets"]
    static let origins = AppStateOrigin.allCases

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
        let origin: AppStateOrigin = rng.next() % 3 == 0 ? (origins.randomElement(using: &rng) ?? .user) : .user
        return AppStateActor(origin: origin, teamAdmin: rng.next() % 4 == 0)
    }

    static func op(_ rng: inout SeededRandom, key: String) -> AppStateOp {
        AppStateOp(key: key, app: apps.randomElement(using: &rng) ?? apps[0], kind: kind(&rng))
    }

    /// A store reached through the reducer: default installs, a team
    /// install, then random ops.
    static func store(_ rng: inout SeededRandom, steps: Int = 25) -> AppStateStore {
        var store = AppDefaultInstalls.bootstrap(AppStateStore(), catalog: [AppCatalogEntry(appID: "cmux/search", tier: .firstParty),
                                                                         AppCatalogEntry(appID: "cmux/inbox", tier: .firstParty)]).0
        if case .success(let (next, _)) = AppStateReducer.apply(AppStateOp(key: "team", app: "acme/team-tool", kind: .install(.team)),
                                                                to: store, actor: AppStateActor(origin: .user, teamAdmin: true)) {
            store = next
        }
        for step in 0..<steps {
            let actor = rng.next() % 3 == 0 ? AppStateActor.system : actor(&rng)
            if case .success(let (next, _)) = AppStateReducer.apply(op(&rng, key: "s\(step)"), to: store, actor: actor) { store = next }
        }
        return store
    }
}
