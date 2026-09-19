import Foundation

extension SurfaceResource {
    /// One provider identity drives the tab strip and every Cloud tree placement.
    /// Report provenance and user-controlled terminal titles are not provider IDs.
    var terminalAgentIconAssetName: String? {
        guard kind == .terminal, lifecycle != .exited,
              let badge = agent, badge.state != "done" else { return nil }

        let definitions = CmuxTaskManagerCodingAgentDefinition.builtIns
        let identities = [badge.agent, badge.source]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && !["hook", "socket", "detected", "plugin", "unknown"].contains($0) }
        if let asset = identities.lazy.compactMap({ identity in
            definitions.first { definition in
                definition.id == identity
                    || definition.launchKinds.contains(identity)
                    || definition.directBasenames.contains(identity)
            }?.assetName
        }).first {
            return asset
        }

        // Older remote daemons report hook provenance without the provider
        // identity. Their terminal title still carries the user-facing agent
        // name, so use it as a compatibility fallback until the daemon is
        // upgraded to emit `agent`.
        let titleTokens = title
            .split(whereSeparator: { $0.isWhitespace || $0 == "✳" })
            .map { String($0).trimmingCharacters(in: .punctuationCharacters).lowercased() }
            .filter { !$0.isEmpty }
        return titleTokens.lazy.compactMap { token in
            definitions.first { definition in
                definition.id == token
                    || definition.displayName.lowercased().split(separator: " ").contains { $0 == token }
                    || definition.launchKinds.contains(token)
                    || definition.directBasenames.contains(token)
            }?.assetName
        }.first
    }
}
