import CmuxNextApps
@testable import CmuxNextAppPermissions
import Foundation
import Testing

/// Seeded property tests for the invariants of first-party-apps.md
/// section 5: each seed builds a reachable record (install draft plus
/// random user changes) and probes every op in the scope table.
@Suite struct AppPermissionPropertyTests {
    nonisolated static let seeds: [UInt64] = Array(0..<300)

    @Test(arguments: seeds)
    func completeSandboxAllowsOnlyHandPickedScopesAndNeverNetworkOrFiles(seed: UInt64) {
        var rng = SeededRandom(seed: seed)
        var record = Fixtures.record(&rng)
        // Into Complete sandbox, then random user changes (hand picks among them).
        for profile in [AppSandboxProfile.standard, .completeSandbox] {
            record = (try? AppGrantReducer.apply(.setProfile(profile), to: record, origin: .user).get()) ?? record
        }
        #expect(record.profile == .completeSandbox && record.grant.sandboxPicks.isEmpty)
        var handPicked: Set<String> = []
        for _ in 0..<Int(rng.next() % 8) {
            let change = Fixtures.change(&rng, record: record)
            if case .setProfile = change { continue }
            guard case .success(let next) = AppGrantReducer.apply(change, to: record, origin: .user) else { continue }
            if case .setApproval(let scope, let approval) = change {
                if approval == .denied { handPicked.remove(scope) } else { handPicked.insert(scope) }
            }
            if case .revokeAll = change { handPicked = [] }
            record = next
        }
        #expect(record.grant.sandboxPicks.isSubset(of: handPicked))
        for (op, params) in Fixtures.probes(&rng) {
            let decision = Fixtures.decide(op, params, record, session: AppSessionApprovals(scopes: Set(Fixtures.scopeUniverse), grantRevision: .max))
            guard decision.permissiveness > 0 else { continue }
            guard case .scope(let scope, _) = AppScopeRequirement.resolve(op: op, params: params, table: Fixtures.table) else {
                #expect(AppScopeRequirement.resolve(op: op, params: params, table: Fixtures.table) == .own)
                continue
            }
            #expect(!op.hasPrefix("net.") && !op.hasPrefix("fs."), "complete sandbox reached \(op)")
            #expect(!AppScopeKind(scope).isNetwork && !AppScopeKind(scope).isFiles)
            #expect(handPicked.contains(scope) || handPicked.contains(record.grant.held(scope)?.scope ?? ""),
                    "\(op) needs \(scope), which the user did not turn on by hand")
        }
    }

    @Test(arguments: seeds)
    func unverifiedNeverHoldsRestrictedScopes(seed: UInt64) {
        var rng = SeededRandom(seed: seed)
        var record = Fixtures.record(&rng, tier: .unverified)
        let origins: [AppGrantChangeOrigin] = [.user, .teamAdmin, .cli, .mcp, .script, .remote]
        for _ in 0..<20 {
            let origin = origins.randomElement(using: &rng) ?? .user
            if case .success(let next) = AppGrantReducer.apply(Fixtures.change(&rng, record: record), to: record, origin: origin) {
                record = next
            }
            let held = record.grant.activeScopes.union(record.grant.requestable)
            let restricted = held.filter { AppScopeKind($0).isRestricted }
            let writableRoots = record.grant.fileRoots.filter(\.writable)
            #expect(restricted.isEmpty, "unverified holds \(restricted)")
            #expect(writableRoots.isEmpty)
        }
        for (op, params) in Fixtures.probes(&rng) {
            guard case .scope(let scope, _) = AppScopeRequirement.resolve(op: op, params: params, table: Fixtures.table),
                  AppScopeKind(scope).isRestricted else { continue }
            let reason = Fixtures.decide(op, params, record).refusal?.reason
            #expect(reason == .tierRestricted || (reason == .disabled && record.grant.disabled), "\(op): \(String(describing: reason))")
        }
    }

    @Test(arguments: seeds.prefix(100))
    func noTierReachesAnOperationOutsideThePublicTable(seed: UInt64) {
        var rng = SeededRandom(seed: seed)
        let record = Fixtures.record(&rng, tier: .firstParty)
        var grant = record.grant
        grant.scopes = Dictionary(uniqueKeysWithValues: Fixtures.scopeUniverse.map { ($0, AppScopeApproval.always) })
        grant.disabled = false
        let everything = AppPermissionRecord(appID: "cmux/x", tier: .firstParty, declared: Set(Fixtures.scopeUniverse),
                                             profile: .standard, grant: grant)
        let invented = (0..<20).map { _ in "op\(rng.next() % 1000).\(["list", "get", "run", "delete"].randomElement(using: &rng) ?? "x")" }
        for op in invented + Array(Fixtures.table.never) + ["app.install", "grant.set", "policy.update", "account.remove"] {
            let decision = Fixtures.decide(op, ["workspace": "ws_1"], everything)
            #expect(!decision.isAllowed)
            #expect([.unsupported, .never].contains(decision.refusal?.reason), "\(op): \(decision)")
        }
        for (op, params) in Fixtures.probes(&rng) where Fixtures.decide(op, params, everything).mayRun {
            #expect(Fixtures.table.ops[op] != nil && !Fixtures.table.never.contains(op))
        }
    }

    @Test(arguments: seeds)
    func revokingNeverWidensAndVoidsOlderCalls(seed: UInt64) {
        var rng = SeededRandom(seed: seed)
        let before = Fixtures.record(&rng)
        let change = Fixtures.narrowing(&rng, record: before)
        guard case .success(let after) = AppGrantReducer.apply(change, to: before, origin: .user) else {
            Issue.record("narrowing change \(change) rejected")
            return
        }
        let session = AppSessionApprovals(scopes: Set(Fixtures.scopeUniverse), grantRevision: before.grant.revision)
        for (op, params) in Fixtures.probes(&rng) {
            let old = Fixtures.decide(op, params, before, session: session)
            let new = Fixtures.decide(op, params, after, session: session)
            #expect(new.permissiveness <= old.permissiveness, "\(change) widened \(op): \(old) -> \(new)")
            if after.grant != before.grant || after.profile != before.profile {
                let pending = AppPendingCall(op: op, params: params, grantRevision: before.grant.revision)
                let admitted = AppPermissionPolicy.admit(pending, grant: after.grant, profile: after.profile, tier: after.tier,
                                                         scopeTable: Fixtures.table, reviewed: after.reviewed)
                #expect(admitted.refusal?.reason == .revoked, "\(change) left a pending \(op) running")
            }
        }
        // A team admin may apply the same narrowing; never a widening.
        #expect((try? AppGrantReducer.apply(change, to: before, origin: .teamAdmin).get()) != nil || after == before)
        #expect(after.grant.revision >= before.grant.revision)
    }

    @Test(arguments: seeds)
    func grantIntersectProfileIsWithinGrant(seed: UInt64) {
        var rng = SeededRandom(seed: seed)
        let record = Fixtures.record(&rng)
        for profile in AppSandboxProfile.allCases {
            let capped = AppPermissionPolicy.capped(record.grant, profile: profile, tier: record.tier, reviewed: record.reviewed)
            for (scope, approval) in capped.scopes {
                let granted = record.grant.scopes[scope]
                #expect(granted != nil, "\(profile) added \(scope)")
                #expect(approval <= (granted ?? .denied), "\(profile) widened \(scope)")
            }
            #expect(capped.requestable.isSubset(of: record.grant.requestable))
            #expect(Set(capped.fileRoots).isSubset(of: Set(record.grant.fileRoots)))
            #expect(capped.selectors.isWithin(record.grant.selectors))
        }
        // A stricter profile never reaches more than a wider one.
        for (op, params) in Fixtures.probes(&rng) {
            let ranks = AppSandboxProfile.allCases.map { profile -> Int in
                var probe = record
                probe.profile = profile
                if profile == .completeSandbox { probe.grant.sandboxPicks = [] }
                return Fixtures.decide(op, params, probe).permissiveness
            }
            #expect(ranks == ranks.sorted(by: >), "\(op): \(ranks)")
        }
    }
}

private extension AppPermissionDecision {
    /// Allowed or asking: a call that may run.
    var mayRun: Bool { permissiveness > 0 }
}
