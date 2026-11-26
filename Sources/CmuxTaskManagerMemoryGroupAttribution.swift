import Foundation

/// Describes whether a memory group has one common owner, several owners, or incomplete attribution.
enum CmuxTaskManagerMemoryGroupAttribution: Sendable {
    case common(CmuxTaskManagerMemoryAttribution)
    case multiple(workspaceCount: Int, ownerCount: Int)
    case partial(attributedProcessCount: Int, unattributedProcessCount: Int)
    case unattributed

    init?(_ payload: [String: Any]) {
        guard let kind = CmuxTaskManagerMemoryDiagnostic.string(payload["kind"]) else {
            return nil
        }
        switch kind {
        case "common":
            guard let owner = CmuxTaskManagerMemoryAttribution(payload["owner"] as? [String: Any]) else {
                return nil
            }
            self = .common(owner)
        case "multiple":
            self = .multiple(
                workspaceCount: CmuxTaskManagerMemoryDiagnostic.int(payload["workspace_count"]) ?? 0,
                ownerCount: CmuxTaskManagerMemoryDiagnostic.int(payload["owner_count"]) ?? 0
            )
        case "partial":
            self = .partial(
                attributedProcessCount: CmuxTaskManagerMemoryDiagnostic.int(
                    payload["attributed_process_count"]
                ) ?? 0,
                unattributedProcessCount: CmuxTaskManagerMemoryDiagnostic.int(
                    payload["unattributed_process_count"]
                ) ?? 0
            )
        case "unattributed":
            self = .unattributed
        default:
            return nil
        }
    }

    var commonOwner: CmuxTaskManagerMemoryAttribution? {
        guard case .common(let owner) = self else { return nil }
        return owner
    }

    var localizedDescription: String {
        switch self {
        case .common(let owner):
            owner.localizedDescription
        case .multiple(let workspaceCount, _):
            if workspaceCount > 1 {
                String.localizedStringWithFormat(
                    String(localized: "memory.attribution.multipleWorkspaces", defaultValue: "%lld workspaces"),
                    workspaceCount
                )
            } else {
                String(localized: "memory.attribution.multipleOwners", defaultValue: "multiple owners")
            }
        case .partial:
            String(localized: "memory.attribution.partial", defaultValue: "partially attributed")
        case .unattributed:
            String(localized: "taskManager.memory.unattributed", defaultValue: "Unattributed")
        }
    }
}
