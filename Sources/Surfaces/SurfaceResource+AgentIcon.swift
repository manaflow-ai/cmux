import Foundation

extension SurfaceResource {
    /// One provider identity drives the tab strip and every Cloud tree placement.
    /// Report provenance and user-controlled terminal titles are not provider IDs.
    var terminalAgentIconAssetName: String? {
        guard kind == .terminal, lifecycle != .exited,
              let badge = agent, badge.state != "done",
              let identity = (badge.agent ?? badge.source)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !identity.isEmpty,
              !["hook", "socket", "detected", "plugin", "unknown"].contains(identity) else { return nil }
        return CmuxTaskManagerCodingAgentDefinition.builtIns.first { definition in
            definition.id == identity
                || definition.launchKinds.contains(identity)
                || definition.directBasenames.contains(identity)
        }?.assetName
    }
}
