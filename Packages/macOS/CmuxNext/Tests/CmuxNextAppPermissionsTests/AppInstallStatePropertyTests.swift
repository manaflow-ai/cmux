@testable import CmuxNextAppPermissions
import Foundation
import Testing

/// Seeded properties of the install-state reducer (app-hide.md).
@Suite struct AppInstallStatePropertyTests {
    nonisolated static let seeds: [UInt64] = Array(0..<300)

    @Test(arguments: seeds)
    func everyCommitKeepsTheInvariants(seed: UInt64) {
        var rng = SeededRandom(seed: seed)
        var store = InstallFixtures.store(&rng, steps: 5)
        for step in 0..<60 {
            let op = InstallFixtures.op(&rng, key: "p\(step)")
            let actor = InstallFixtures.actor(&rng)
            let before = store
            let old = before.state(op.app)
            guard case .success(let (next, commit)) = AppStateReducer.apply(op, to: before, actor: actor) else {
                continue
            }
            store = next
            let new = next.state(op.app)
            // hidden ⇒ installed, for every record.
            let broken = next.apps.values.filter { $0.hidden && !$0.installed }.map(\.appID)
            #expect(broken.isEmpty, "hidden but not installed: \(broken)")
            // Only the op's app changes; its revision moves by one exactly when it changes.
            let others = next.apps.filter { $0.key != op.app }
            #expect(others == before.apps.filter { $0.key != op.app })
            #expect(new == old || new.revision == old.revision + 1)
            // Channels that never change app state.
            #expect(![.mcp, .automation, .remote].contains(actor.origin), "\(actor.origin) changed state with \(op)")
            switch op.kind {
            case .hide, .unhide:
                // Hide and unhide touch only `hidden`: no grant, storage or layout event.
                var expected = old
                expected.hidden = op.kind == .hide
                expected.revision = new.revision
                #expect(new == expected)
                #expect(commit.events.allSatisfyChanged)
            case .remove where commit.outcome == .applied:
                #expect(!new.installed && !new.enabled && !new.hidden)
                #expect(commit.events.contains(.storageRemoved(app: op.app)) && commit.events.contains(.grantRemoved(app: op.app)))
                #expect(old.source != .team || actor.teamAdmin)
                #expect(old.source != .default || op.kind == .remove(confirmed: true))
            case .remove where commit.outcome == .convertedToHide:
                #expect(old.source == .default && new.installed && new.hidden && new.enabled == old.enabled)
                #expect(commit.events.allSatisfyChanged)
            case .enable, .disable, .setHiddenAccess:
                #expect(commit.events.allSatisfyChanged)
                #expect(new.hidden == old.hidden && new.source == old.source)
            default:
                break
            }
            // Idempotent replay: the same key and op has no further effect.
            if case .success(let (replayed, again)) = AppStateReducer.apply(op, to: next, actor: actor) {
                #expect(replayed == next && again.outcome == .replayed && again.events.isEmpty)
            } else {
                Issue.record("replay of \(op) was rejected")
            }
            var other = op
            other.kind = op.kind == .hide ? .unhide : .hide
            #expect(AppStateReducer.apply(other, to: next, actor: actor).rejected == .keyReused)
        }
    }

    @Test(arguments: seeds.prefix(100))
    func teamMembersHideAndDisableButOnlyAdminsRemove(seed: UInt64) {
        var rng = SeededRandom(seed: seed)
        let store = InstallFixtures.store(&rng, steps: 0)
        let member = AppStateActor(origin: rng.next() % 2 == 0 ? .user : .cli, teamAdmin: false)
        let app = "acme/team-tool"
        #expect(store.state(app).source == .team)
        for kind in [AppStateOp.Kind.hide, .disable, .unhide, .enable] {
            #expect(AppStateReducer.apply(AppStateOp(key: "\(kind)", app: app, kind: kind), to: store, actor: member).rejected == nil)
        }
        #expect(AppStateReducer.apply(AppStateOp(key: "rm", app: app, kind: .remove(confirmed: true)), to: store, actor: member)
            .rejected == .adminOnly)
        let admin = AppStateActor(origin: member.origin, teamAdmin: true)
        let removed = AppStateReducer.apply(AppStateOp(key: "rm", app: app, kind: .remove(confirmed: true)), to: store, actor: admin)
        #expect(removed.accepted?.0.state(app).installed == false)
    }

    @Test func defaultInstallsSkipSamplesAndRespectConfirmedRemoval() throws {
        let catalog = [AppCatalogEntry(appID: "cmux/search", tier: .firstParty), AppCatalogEntry(appID: "cmux/usage", tier: .firstParty),
                       AppCatalogEntry(appID: "cmux/github-prs", tier: .firstParty, isSample: true),
                       AppCatalogEntry(appID: "acme/board", tier: .verified)]
        let (store, events) = AppDefaultInstalls.bootstrap(AppStateStore(), catalog: catalog)
        #expect(Set(store.apps.values.filter(\.installed).map(\.appID)) == ["cmux/search", "cmux/usage"])
        #expect(store.state("cmux/search").source == .default && store.state("cmux/search").enabled)
        #expect(events.count == 2)
        #expect(AppDefaultInstalls.bootstrap(store, catalog: catalog).1.isEmpty)

        // Unconfirmed Remove of a default app hides it.
        let soft = try AppStateReducer.apply(AppStateOp(key: "r1", app: "cmux/usage", kind: .remove(confirmed: false)), to: store, actor: .user).get()
        #expect(soft.1.outcome == .convertedToHide && soft.0.state("cmux/usage").hidden && soft.0.state("cmux/usage").installed)
        // Confirmed removal sticks, even after the owner prunes receipts.
        var hard = try AppStateReducer.apply(AppStateOp(key: "r2", app: "cmux/usage", kind: .remove(confirmed: true)), to: store, actor: .user).get().0
        hard.receipts = [:]
        #expect(AppDefaultInstalls.bootstrap(hard, catalog: catalog).0.state("cmux/usage").installed == false)
        // Only the owner makes default installs; only the user installs.
        let fake = AppStateOp(key: "x", app: "cmux/notes", kind: .install(.default))
        #expect(AppStateReducer.apply(fake, to: store, actor: .user).rejected == .originNotAllowed(.user))
        let viaMCP = AppStateOp(key: "y", app: "acme/board", kind: .install(.user))
        #expect(AppStateReducer.apply(viaMCP, to: store, actor: AppStateActor(origin: .mcp)).rejected == .originNotAllowed(.mcp))
        #expect(AppStateReducer.apply(AppStateOp(key: "z", app: "cmux/search", kind: .setHiddenAccess(cli: false, mcp: nil, automations: nil)),
                                      to: store, actor: .cli).rejected == .originNotAllowed(.cli))
        #expect(AppStateReducer.apply(AppStateOp(key: "w", app: "acme/board", kind: .hide), to: store, actor: .user).rejected == .notInstalled)
    }
}

extension [AppStateEvent] {
    /// Only `changed` events (no grant, storage or layout effect).
    var allSatisfyChanged: Bool {
        allSatisfy { if case .changed = $0 { true } else { false } }
    }
}

extension Result {
    var rejected: Failure? { if case .failure(let error) = self { error } else { nil } }
    var accepted: Success? { if case .success(let value) = self { value } else { nil } }
}
