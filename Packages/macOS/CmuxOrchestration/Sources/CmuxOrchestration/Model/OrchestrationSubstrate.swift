import Foundation

/// How task workspaces are provisioned for a run.
///
/// The substrate is the seam between "what the template wants" and "how
/// directories appear on the user's machine". cmux implements `worktree` and
/// `clonePool` natively; `script` is the escape hatch where the template
/// supplies provision/reset scripts (SSH, cloud VMs, anything). Script
/// substrates are surfaced prominently in the trust summary because they run
/// template-authored code on the user's machine.
public enum OrchestrationSubstrate: Sendable, Hashable, Codable {
    /// One git worktree per task, created from the target repository.
    /// `branchPrefix` seeds task branch names (default: the template name).
    case worktree(branchPrefix: String?)
    /// A pool of `poolSize` full clones, reset between tasks.
    case clonePool(poolSize: Int?)
    /// Template-supplied provision/reset scripts, relative to the template
    /// root. Defaults: `scripts/provision-workspace` and
    /// `scripts/reset-workspace`.
    case script(provision: String, reset: String?)

    public static let defaultProvisionScriptPath = "scripts/provision-workspace"
    public static let defaultResetScriptPath = "scripts/reset-workspace"

    /// The `kind` discriminator string used in `orchestration.json`.
    public var kind: Kind {
        switch self {
        case .worktree: return .worktree
        case .clonePool: return .clonePool
        case .script: return .script
        }
    }

    public enum Kind: String, Sendable, Codable, CaseIterable {
        case worktree
        case clonePool = "clone-pool"
        case script
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case branchPrefix
        case poolSize
        case provision
        case reset
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kindString = try container.decode(String.self, forKey: .kind)
        guard let kind = Kind(rawValue: kindString) else {
            let allowed = Kind.allCases.map(\.rawValue).joined(separator: ", ")
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown substrate kind '\(kindString)'; expected one of: \(allowed)"
            )
        }
        switch kind {
        case .worktree:
            self = .worktree(branchPrefix: try container.decodeIfPresent(String.self, forKey: .branchPrefix))
        case .clonePool:
            self = .clonePool(poolSize: try container.decodeIfPresent(Int.self, forKey: .poolSize))
        case .script:
            self = .script(
                provision: try container.decodeIfPresent(String.self, forKey: .provision)
                    ?? Self.defaultProvisionScriptPath,
                reset: try container.decodeIfPresent(String.self, forKey: .reset)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .kind)
        switch self {
        case .worktree(let branchPrefix):
            try container.encodeIfPresent(branchPrefix, forKey: .branchPrefix)
        case .clonePool(let poolSize):
            try container.encodeIfPresent(poolSize, forKey: .poolSize)
        case .script(let provision, let reset):
            try container.encode(provision, forKey: .provision)
            try container.encodeIfPresent(reset, forKey: .reset)
        }
    }

    /// Template-relative script paths this substrate would execute at run
    /// time. Empty for cmux-native substrates.
    public var scriptPaths: [String] {
        switch self {
        case .worktree, .clonePool:
            return []
        case .script(let provision, let reset):
            return [provision] + (reset.map { [$0] } ?? [])
        }
    }
}
