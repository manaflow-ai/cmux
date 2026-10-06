import CmuxNextApps
@testable import CmuxNextAppPermissions
import Foundation

/// SplitMix64: a seeded generator so every property run is reproducible.
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum Fixtures {
    /// The bundled public table plus the proposed operations (fs, usage, CodeRouter).
    static let table = AppScopeTable.bundled.addingProposedOperations()

    static let hosts = ["api.example.com", "files.example.org", "status.example.net"]
    static let roots = [AppFileRoot(id: "root_a", kind: .bookmark, label: "Notes"),
                        AppFileRoot(id: "root_b", kind: .workspaceFolder, label: "repo", writable: true)]
    static let workspaces = ["ws_1", "ws_2", "ws_3"]

    /// Every scope a random manifest may declare.
    static let scopeUniverse: [String] = {
        var scopes = Set(table.ops.values.map(\.scope)).filter { !$0.contains("<") && $0 != "storage:local" }
        scopes.formUnion(hosts.map { "net:\($0)" })
        scopes.formUnion(["net:*.example.com", "integration:github", "integration:github:read", "storage:synced"])
        scopes.formUnion(restrictedSamples)
        return scopes.sorted()
    }()

    /// Restricted scopes of the shared scope table (`scope-classes.json`).
    static let restrictedSamples: Set<String> = ["coderouter:keys", "usage:read", "fs:write", "mcp:expose", "clipboard:write",
                                                 "feed:answer", "terminal:input"]

    /// Ops to probe, with params that name hosts, roots and workspaces.
    static func probes(_ rng: inout SeededRandom) -> [(String, AppJSON)] {
        var out: [(String, AppJSON)] = []
        for op in table.ops.keys.sorted() {
            var params: [String: AppJSON] = [:]
            if rng.next() % 2 == 0 { params["workspace"] = .string(workspaces.randomElement(using: &rng) ?? "ws_1") }
            if op.hasPrefix("fs.") { params["root"] = .string(["root_a", "root_b", "root_x"].randomElement(using: &rng) ?? "root_a") }
            if op == "net.fetch" { params["url"] = .string("https://\((hosts + ["cdn.example.com"]).randomElement(using: &rng) ?? "")/x") }
            if op == "integration.request" {
                params["provider"] = "github"
                params["method"] = .string(rng.next() % 2 == 0 ? "GET" : "POST")
            }
            out.append((op, .object(params)))
        }
        out.append(("made.up.operation", [:]))
        out.append(("app.install", [:]))
        return out
    }

    /// A random record reached through the real install draft and a random
    /// sequence of user grant changes.
    static func record(_ rng: inout SeededRandom, tier: AppTier? = nil) -> AppPermissionRecord {
        let tier = tier ?? AppTier.allCases.randomElement(using: &rng) ?? .verified
        let declared = scopeUniverse.filter { _ in rng.next() % 3 == 0 }
        let required = declared.filter { _ in rng.next() % 2 == 0 }
        let optional = declared.filter { !required.contains($0) }
        let reviewed: Set<String> = tier == .verified ? restrictedSamples.filter { _ in rng.next() % 2 == 0 } : []
        var draft = AppInstallDraft(appID: "pub/app", tier: tier, required: required.map { AppScopeRequest(scope: $0, reason: "r") },
                                    optional: optional.map { AppScopeRequest(scope: $0, reason: "r") }, reviewed: reviewed,
                                    profile: AppSandboxProfile.allCases.randomElement(using: &rng))
        for row in draft.rows where rng.next() % 3 == 0 { draft.set(row.scope, on: !draft.isOn(row.scope)) }
        var record = draft.record()
        for _ in 0..<Int(rng.next() % 10) {
            if case .success(let next) = AppGrantReducer.apply(change(&rng, record: record), to: record, origin: .user) { record = next }
        }
        return record
    }

    /// Any change (widening or narrowing).
    static func change(_ rng: inout SeededRandom, record: AppPermissionRecord) -> AppGrantChange {
        let scope = record.declared.sorted().randomElement(using: &rng) ?? "workspace:read"
        switch rng.next() % 8 {
        case 0, 1: return .setApproval(scope: scope, approval: AppScopeApproval.allCases.randomElement(using: &rng) ?? .always)
        case 2: return .setProfile(AppSandboxProfile.allCases.randomElement(using: &rng) ?? .standard)
        case 3: return .addFileRoot(roots.randomElement(using: &rng) ?? roots[0])
        case 4: return .removeFileRoot(id: roots.randomElement(using: &rng)?.id ?? "root_a")
        case 5: return .setSelectors(rng.next() % 2 == 0 ? .any : AppResourceSelectors(workspaces: Set(workspaces.filter { _ in rng.next() % 2 == 0 })))
        case 6: return .answerFirstUse(scope: record.grant.requestable.sorted().randomElement(using: &rng) ?? scope,
                                       answer: AppFirstUseAnswer.allCases.randomElement(using: &rng) ?? .allow)
        default: return rng.next() % 4 == 0 ? .revokeAll : .enable
        }
    }

    /// A change that only removes reach.
    static func narrowing(_ rng: inout SeededRandom, record: AppPermissionRecord) -> AppGrantChange {
        let held = record.grant.scopes.keys.sorted()
        switch rng.next() % 6 {
        case 0 where !held.isEmpty:
            let scope = held.randomElement(using: &rng) ?? held[0]
            let current = record.grant.scopes[scope] ?? .denied
            // In Complete sandbox, any approval on an unpicked scope is a
            // hand pick (a widening); only turning it off narrows.
            if record.profile == .completeSandbox, !record.grant.sandboxPicks.contains(scope) {
                return .setApproval(scope: scope, approval: .denied)
            }
            let lower = AppScopeApproval.allCases.filter { $0 <= current }
            return .setApproval(scope: scope, approval: lower.randomElement(using: &rng) ?? .denied)
        case 1:
            let stricter = AppSandboxProfile.allCases.filter { $0 >= record.profile }
            return .setProfile(stricter.randomElement(using: &rng) ?? .completeSandbox)
        case 2:
            return .removeFileRoot(id: record.grant.fileRoots.randomElement(using: &rng)?.id ?? "root_a")
        case 3:
            let base = record.grant.selectors.workspaces ?? Set(workspaces)
            return .setSelectors(AppResourceSelectors(workspaces: base.filter { _ in rng.next() % 2 == 0 },
                                                      rooms: record.grant.selectors.rooms, machines: record.grant.selectors.machines))
        case 4 where !record.grant.requestable.isEmpty && record.profile != .completeSandbox:
            return .answerFirstUse(scope: record.grant.requestable.sorted().randomElement(using: &rng) ?? "", answer: .deny)
        default:
            return .revokeAll
        }
    }

    static func decide(_ op: String, _ params: AppJSON, _ record: AppPermissionRecord,
                       session: AppSessionApprovals = .none) -> AppPermissionDecision {
        AppPermissionPolicy.effectiveDecision(op: op, params: params, grant: record.grant, profile: record.profile, tier: record.tier,
                                              scopeTable: table, reviewed: record.reviewed, session: session)
    }
}
