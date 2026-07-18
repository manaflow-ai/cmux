import Foundation

/// Why a process generation owns, or cannot own, session restoration.
///
/// Child authority is monotonic only when its evidence is durable. An ancestry
/// walk that stopped inconclusively is provisional: it fails closed, but an
/// explicitly forked session may recover if a later complete walk proves that
/// it has no agent ancestor. Managed, explicit-spawn, verified-ancestor, and
/// legacy child records never recover authority.
enum AgentSessionAuthorityEvidence: String, Codable, Sendable, Equatable {
    case verifiedForkRoot = "verified_fork_root"
    case managedChild = "managed_child"
    case explicitSpawnedChild = "explicit_spawned_child"
    case verifiedAncestorChild = "verified_ancestor_child"
    case provisionalAmbiguousChild = "provisional_ambiguous_child"
    case legacyChild = "legacy_child"

    var isDurableChild: Bool {
        switch self {
        case .managedChild, .explicitSpawnedChild, .verifiedAncestorChild, .legacyChild:
            true
        case .verifiedForkRoot, .provisionalAmbiguousChild:
            false
        }
    }
}

struct AgentSessionAuthorityTransition: Sendable {
    func persistedEvidence(for run: AgentSessionRunRecord) -> AgentSessionAuthorityEvidence? {
        run.authorityEvidence ?? (run.relationship == .spawned ? .legacyChild : nil)
    }

    func canRecoverProvisionalFork(
        previous: AgentSessionAuthorityEvidence?,
        incoming: AgentHookSessionLineage
    ) -> Bool {
        previous == .provisionalAmbiguousChild
            && incoming.authorityEvidence == .verifiedForkRoot
            && incoming.relationship == .forked
            && incoming.restoreAuthority
    }
}
