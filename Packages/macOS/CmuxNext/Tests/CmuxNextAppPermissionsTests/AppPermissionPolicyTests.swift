import CmuxNextApps
@testable import CmuxNextAppPermissions
import Foundation
import Testing

@Suite struct AppPermissionPolicyTests {
    private func record(_ tier: AppTier, _ scopes: [String: AppScopeApproval], profile: AppSandboxProfile = .standard,
                        requestable: Set<String> = [], roots: [AppFileRoot] = [], reviewed: Set<String> = []) -> AppPermissionRecord {
        AppPermissionRecord(appID: "pub/app", tier: tier, reviewed: reviewed, declared: Set(scopes.keys).union(requestable),
                            profile: profile, grant: AppGrant(scopes: scopes, requestable: requestable, fileRoots: roots))
    }

    private func requests(_ scopes: [String]) -> [AppScopeRequest] { scopes.map { AppScopeRequest(scope: $0, reason: "why") } }

    // MARK: Tier defaults

    @Test func firstPartyGrantsRequiredScopesAndLeavesOptionalForFirstUse() {
        let draft = AppInstallDraft(appID: "cmux/coderouter", tier: .firstParty, required: requests(["coderouter:read", "coderouter:keys"]),
                                    optional: requests(["notification:write"]))
        let record = draft.record()
        #expect(record.profile == .standard)
        #expect(record.grant.scopes == ["coderouter:read": .always, "coderouter:keys": .always])
        #expect(record.grant.requestable == ["notification:write"])
    }

    @Test func verifiedLeavesExecuteAndExternalOffAndLocksUnreviewedRestricted() {
        let draft = AppInstallDraft(appID: "pub/app", tier: .verified,
                                    required: requests(["workspace:read", "terminal:execute", "integration:github", "net:api.example.com",
                                                        "clipboard:write", "mcp:expose"]),
                                    optional: [], reviewed: ["clipboard:write"])
        #expect(draft.isOn("workspace:read") && draft.isOn("net:api.example.com") && draft.isOn("clipboard:write"))
        #expect(!draft.isOn("terminal:execute") && !draft.isOn("integration:github"))
        #expect(draft.rows.first { $0.scope == "mcp:expose" }?.holdable == false)
        #expect(draft.record().grant.scopes["mcp:expose"] == nil)
    }

    @Test func unverifiedStartsContainedWithReadScopesOnly() {
        var draft = AppInstallDraft(appID: "pub/app", tier: .unverified,
                                    required: requests(["workspace:read", "workspace:write", "terminal:execute", "net:api.example.com", "fs:write"]),
                                    optional: [])
        #expect(draft.profile == .contained)
        #expect(draft.rows.filter { draft.isOn($0.scope) }.map(\.scope) == ["workspace:read"])
        draft.set("terminal:execute", on: true)
        draft.set("net:api.example.com", on: true)
        draft.set("fs:write", on: true)
        let grant = draft.record().grant
        #expect(grant.scopes["terminal:execute"] == .perSession && grant.scopes["net:api.example.com"] == .perSession)
        #expect(grant.scopes["fs:write"] == nil)
    }

    @Test func installSandboxedStartsWithEverythingOff() {
        var draft = AppInstallDraft(appID: "cmux/search", tier: .firstParty, required: requests(["workspace:read", "terminal:read"]), optional: [])
        draft.setProfile(.completeSandbox)
        #expect(!draft.isOn("workspace:read"))
        draft.set("terminal:read", on: true)
        let record = draft.record()
        #expect(record.grant.sandboxPicks == ["terminal:read"])
        #expect(Fixtures.decide("terminal.list", [:], record).isAllowed)
        #expect(Fixtures.decide("workspace.list", [:], record).refusal?.reason == .profile)
    }

    // MARK: Decisions

    @Test func ownStorageNeverAndUnknownOps() {
        let r = record(.unverified, [:])
        #expect(Fixtures.decide("app.storage.get", [:], r) == .allow)
        #expect(Fixtures.decide("app.install", [:], r).refusal?.reason == .never)
        #expect(Fixtures.decide("app.install", [:], r).refusal?.error.code == "operation.forbidden")
        #expect(Fixtures.decide("not.an.op", [:], r).refusal?.reason == .unsupported)
    }

    @Test func networkNeedsHttpsAndAGrantedHost() {
        let r = record(.verified, ["net:api.example.com": .always, "net:*.example.org": .always])
        #expect(Fixtures.decide("net.fetch", ["url": "https://api.example.com/v1"], r) == .allow)
        #expect(Fixtures.decide("net.fetch", ["url": "https://files.example.org/a"], r) == .allow)
        #expect(Fixtures.decide("net.fetch", ["url": "https://example.org/a"], r).refusal?.reason == .scopeMissing)
        #expect(Fixtures.decide("net.fetch", ["url": "http://api.example.com/v1"], r).refusal?.reason == .invalidParams)
        #expect(Fixtures.decide("net.fetch", ["url": "https://evil.example.net"], r).refusal?.error.code == "scope.missing")
    }

    @Test func containedCapsNetworkPerSessionAndExecutePerCall() {
        let r = record(.unverified, ["net:api.example.com": .always, "terminal:execute": .always, "workspace:write": .always],
                       profile: .contained)
        #expect(Fixtures.decide("net.fetch", ["url": "https://api.example.com"], r) == .ask(.perSession, scope: "net:api.example.com"))
        let execute = Fixtures.table.ops.first { $0.value.scope == "terminal:execute" }?.key ?? ""
        #expect(Fixtures.decide(execute, [:], r) == .ask(.perCall, scope: "terminal:execute"))
        let session = AppSessionApprovals(scopes: ["net:api.example.com"], grantRevision: r.grant.revision)
        #expect(Fixtures.decide("net.fetch", ["url": "https://api.example.com"], r, session: session) == .allow)
    }

    @Test func filesNeedAGrantedRootAndWritableForWrites() {
        let roots = [AppFileRoot(id: "r1", kind: .bookmark, label: "Notes"), AppFileRoot(id: "r2", kind: .bookmark, label: "Out", writable: true)]
        let r = record(.firstParty, ["fs:read": .always, "fs:write": .always], roots: roots)
        #expect(Fixtures.decide("fs.read", ["root": "r1", "path": "a.md"], r) == .allow)
        #expect(Fixtures.decide("fs.read", ["root": "r9"], r).refusal?.reason == .outsideResources)
        #expect(Fixtures.decide("fs.write", ["root": "r1"], r).refusal?.reason == .outsideResources)
        #expect(Fixtures.decide("fs.write", ["root": "r2"], r) == .allow)
        #expect(Fixtures.decide("fs.read", [:], r).refusal?.reason == .invalidParams)
        var contained = r
        contained.profile = .contained
        #expect(Fixtures.decide("fs.read", ["root": "r1"], contained).refusal?.reason == .profile)
    }

    @Test func selectorsNarrowWorkspaceOps() {
        var r = record(.verified, ["workspace:read": .always])
        r.grant.selectors = AppResourceSelectors(workspaces: ["ws_1"])
        #expect(Fixtures.decide("workspace.list", ["workspace": "ws_1"], r) == .allow)
        #expect(Fixtures.decide("workspace.list", ["workspace": "ws_2"], r).refusal?.reason == .outsideResources)
    }

    @Test func optionalScopeAsksOnFirstUseExceptInCompleteSandbox() {
        var r = record(.firstParty, [:], requestable: ["notification:write"])
        let op = Fixtures.table.ops.first { $0.value.scope == "notification:write" }?.key ?? ""
        #expect(Fixtures.decide(op, [:], r) == .ask(.firstUse, scope: "notification:write"))
        r.profile = .completeSandbox
        #expect(Fixtures.decide(op, [:], r).refusal?.reason == .profile || Fixtures.decide(op, [:], r).refusal?.reason == .scopeMissing)
        #expect(AppGrantReducer.apply(.answerFirstUse(scope: "notification:write", answer: .allow), to: r, origin: .user)
                == .failure(.notRequestable(scope: "notification:write")))
    }

    // MARK: Grant changes

    @Test func onlyTheUserChangesGrants() {
        let r = record(.verified, ["workspace:read": .denied])
        for origin in [AppGrantChangeOrigin.cli, .mcp, .script, .remote] {
            #expect(AppGrantReducer.apply(.setApproval(scope: "workspace:read", approval: .always), to: r, origin: origin)
                    == .failure(.originNotAllowed(origin)))
        }
        #expect(AppGrantReducer.apply(.setApproval(scope: "workspace:read", approval: .always), to: r, origin: .teamAdmin)
                == .failure(.originNotAllowed(.teamAdmin)))
        #expect((try? AppGrantReducer.apply(.setProfile(.completeSandbox), to: r, origin: .teamAdmin).get())?.profile == .completeSandbox)
        #expect(AppGrantReducer.apply(.setApproval(scope: "terminal:read", approval: .always), to: r, origin: .user)
                == .failure(.undeclared(scope: "terminal:read")))
    }

    @Test func revokeBumpsRevisionAndRefusesPendingCalls() throws {
        let r = record(.verified, ["workspace:read": .always])
        let pending = AppPendingCall(op: "workspace.list", params: [:], grantRevision: r.grant.revision)
        let widened = try AppGrantReducer.apply(.addFileRoot(Fixtures.roots[0]), to: r, origin: .user).get()
        #expect(widened.grant.revision == r.grant.revision + 1 && widened.grant.narrowedAt == r.grant.narrowedAt)
        #expect(AppPermissionPolicy.admit(pending, grant: widened.grant, profile: widened.profile, tier: widened.tier,
                                          scopeTable: Fixtures.table) == .allow)
        let revoked = try AppGrantReducer.apply(.revokeAll, to: widened, origin: .user).get()
        #expect(revoked.grant.disabled && revoked.grant.narrowedAt == revoked.grant.revision)
        let admitted = AppPermissionPolicy.admit(pending, grant: revoked.grant, profile: revoked.profile, tier: revoked.tier,
                                                 scopeTable: Fixtures.table)
        #expect(admitted.refusal?.error.code == "grant.revoked")
        let enabled = try AppGrantReducer.apply(.enable, to: revoked, origin: .user).get()
        #expect(Fixtures.decide("workspace.list", [:], enabled).refusal?.reason == .scopeMissing)
    }

    @Test func firstUseAnswers() throws {
        let r = record(.unverified, [:], requestable: ["net:api.example.com"])
        #expect(try AppGrantReducer.apply(.answerFirstUse(scope: "net:api.example.com", answer: .allowOnce), to: r, origin: .user).get() == r)
        let allowed = try AppGrantReducer.apply(.answerFirstUse(scope: "net:api.example.com", answer: .allow), to: r, origin: .user).get()
        #expect(allowed.grant.scopes["net:api.example.com"] == .perSession)
        let denied = try AppGrantReducer.apply(.answerFirstUse(scope: "net:api.example.com", answer: .deny), to: r, origin: .user).get()
        #expect(Fixtures.decide("net.fetch", ["url": "https://api.example.com"], denied).refusal?.reason == .scopeMissing)
    }

    @Test func scopeClassification() {
        #expect(AppScopeKind("workspace:read").risk.tone == .neutral)
        #expect(AppScopeKind("net:api.example.com").risk.tone == .warning)
        #expect(AppScopeKind("terminal:execute").axis == .processes && AppScopeKind("terminal:execute").risk.tone == .danger)
        #expect(AppScopeKind("integration:github:read").risk == .read && AppScopeKind("integration:github").risk == .external)
        #expect(AppScopeKind("coderouter:keys").isRestricted && AppScopeKind("fs:write:r1").isRestricted)
        let asked: Set<String> = ["workspace:read", "fs:write", "feed:answer", "coderouter:keys", "git:write"]
        #expect(AppPermissionPolicy.refusedScopes(asked, for: .unverified) == ["fs:write", "feed:answer", "coderouter:keys"])
        #expect(AppPermissionPolicy.refusedScopes(asked, for: .firstParty).isEmpty)
    }

    @Test func elevatedScopesNeverStartCheckedAndAnyTierMayHoldThem() {
        let kind = AppScopeKind("terminal:backend")
        #expect(kind.isElevated && !kind.isRestricted)
        for tier in AppTier.allCases {
            #expect(!AppInstallDraft.onByDefault(kind, tier: tier), "\(tier)")
            #expect(AppPermissionPolicy.mayHold("terminal:backend", tier: tier), "\(tier)")
        }
        // The consent title names the effect (coordinator, Cloud connector grant); the app's
        // own reason (for Cloud: "Open terminals on your Cloud machines.") shows under it.
        #expect(AppScopeStrings.title("terminal:backend") == "Open terminals on other machines for you")
    }
}
