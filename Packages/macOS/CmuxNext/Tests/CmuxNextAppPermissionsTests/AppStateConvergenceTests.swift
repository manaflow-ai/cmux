@testable import CmuxNextAppPermissions
import Foundation
import Testing

/// Two clients hide, unhide, enable and remove concurrently through one
/// owner. The network reorders and duplicates ops and events; clients
/// retry with the same key. When every queue drains, both clients'
/// mirrors equal the owner, and the owner equals an independently written
/// reference model of the same arrival order.
@Suite struct AppStateConvergenceTests {
    nonisolated static let seeds: [UInt64] = Array(0..<300)

    enum Message: Hashable {
        case event(AppInstallState)
        case settled(key: String)
    }

    struct Client {
        var actor: AppStateActor
        var mirror: [String: AppInstallState]
        var pending: [AppStateOp] = []
        var inbox: [Message] = []

        mutating func receive(_ message: Message) {
            switch message {
            case .event(let state):
                if (mirror[state.appID]?.revision ?? 0) < state.revision || mirror[state.appID] == nil { mirror[state.appID] = state }
            case .settled(let key):
                pending.removeAll { $0.key == key }
            }
        }

        /// Mirror plus pending intents.
        var visible: [String: AppInstallState] {
            var store = AppStateStore(apps: mirror)
            for op in pending {
                if case .success(let (next, _)) = AppStateReducer.apply(op, to: store, actor: actor) { store = next }
            }
            return store.apps
        }
    }

    @Test(arguments: seeds)
    func twoClientsConvergeOnTheOwner(seed: UInt64) {
        var rng = SeededRandom(seed: seed)
        var owner = InstallFixtures.store(&rng, steps: 8)
        var reference = ReferenceModel(owner)
        var clients = [Client(actor: .user, mirror: owner.apps), Client(actor: .cli, mirror: owner.apps)]
        var wire: [(client: Int, op: AppStateOp)] = []
        var nextKey = 0

        func deliverToOwner(_ index: Int) {
            let (sender, op) = wire.remove(at: index)
            let actor = clients[sender].actor
            reference.apply(op, actor: actor)
            switch AppStateReducer.apply(op, to: owner, actor: actor) {
            case .success(let (next, commit)):
                owner = next
                for event in commit.events {
                    guard case .changed(let state) = event else { continue }
                    for c in clients.indices {
                        clients[c].inbox.append(.event(state))
                        if rng.next() % 4 == 0 { clients[c].inbox.append(.event(state)) }
                    }
                }
            case .failure:
                break
            }
            clients[sender].inbox.append(.settled(key: op.key))
        }

        for _ in 0..<120 {
            let c = Int(rng.next() % 2)
            switch rng.next() % 6 {
            case 0, 1:
                // A user action: a new intent with a fresh key.
                nextKey += 1
                let op = InstallFixtures.op(&rng, key: "k\(nextKey)")
                if case .install(.default) = op.kind { continue }
                clients[c].pending.append(op)
                wire.append((c, op))
            case 2:
                // A retry of a pending intent with the same key.
                if let op = clients[c].pending.randomElement(using: &rng) { wire.append((c, op)) }
            case 3, 4:
                if !wire.isEmpty { deliverToOwner(Int(rng.next() % UInt64(wire.count))) }
            default:
                if !clients[c].inbox.isEmpty {
                    clients[c].receive(clients[c].inbox.remove(at: Int(rng.next() % UInt64(clients[c].inbox.count))))
                }
            }
        }
        while !wire.isEmpty { deliverToOwner(Int(rng.next() % UInt64(wire.count))) }
        for c in clients.indices {
            while !clients[c].inbox.isEmpty {
                clients[c].receive(clients[c].inbox.remove(at: Int(rng.next() % UInt64(clients[c].inbox.count))))
            }
        }

        for client in clients {
            #expect(client.pending.isEmpty)
            #expect(client.mirror == owner.apps)
            #expect(client.visible == owner.apps)
        }
        #expect(reference.apps == ReferenceModel(owner).apps)
    }
}

/// The C7 rules written directly, without the reducer's structure.
struct ReferenceModel {
    struct App: Equatable {
        var source: AppInstallSource?
        var enabled = false
        var hidden = false
        var access = AppHiddenAccess.all
    }

    var apps: [String: App] = [:]
    var accepted: Set<String> = []
    var removedDefaults: Set<String> = []

    init(_ store: AppStateStore) {
        for (id, state) in store.apps where state.installed || state != .notInstalled(id) {
            apps[id] = App(source: state.source, enabled: state.enabled, hidden: state.hidden, access: state.hiddenAccess)
        }
        apps = apps.filter { $0.value != App() }
        accepted = Set(store.receipts.keys)
        removedDefaults = store.removedDefaults
    }

    mutating func apply(_ op: AppStateOp, actor: AppStateActor) {
        if accepted.contains(op.key) { return }
        var app = apps[op.app] ?? App()
        let userOrCLI = actor.origin == .user || actor.origin == .cli
        switch op.kind {
        case .install(let source):
            guard source == .default ? actor.origin == .system : actor.origin == .user else { return }
            if source == .team, !actor.teamAdmin { return }
            if source != .default { removedDefaults.remove(op.app) }
            if app.source == nil, !(source == .default && removedDefaults.contains(op.app)) {
                app = App(source: source, enabled: true)
            }
        case .remove(let confirmed):
            guard userOrCLI, let source = app.source else { return }
            if source == .team, !actor.teamAdmin { return }
            if source == .default, !confirmed {
                app.hidden = true
            } else {
                if source == .default { removedDefaults.insert(op.app) }
                app = App()
            }
        case .setHiddenAccess(let cli, let mcp, let automations):
            guard actor.origin == .user, app.source != nil else { return }
            app.access = AppHiddenAccess(cli: cli ?? app.access.cli, mcp: mcp ?? app.access.mcp, automations: automations ?? app.access.automations)
        case .enable, .disable, .hide, .unhide:
            guard userOrCLI, app.source != nil else { return }
            if op.kind == .enable { app.enabled = true }
            if op.kind == .disable { app.enabled = false }
            if op.kind == .hide { app.hidden = true }
            if op.kind == .unhide { app.hidden = false }
        }
        accepted.insert(op.key)
        apps[op.app] = app == App() ? nil : app
    }
}
