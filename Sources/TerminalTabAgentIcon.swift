import Foundation

/// Resolves a provider mark from the same agent definitions used by process
/// and hook detection. Local terminal tabs never use it: they always show
/// `terminal.fill` (#7822, pinned by `TerminalTabIconRegressionTests`).
struct TerminalTabAgentIconResolver {
    func assetName(forStatusKey statusKey: String) -> String? {
        let normalized = statusKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return CmuxTaskManagerCodingAgentDefinition.builtIns.first { definition in
            definition.id == normalized
                || definition.launchKinds.contains(normalized)
                || definition.directBasenames.contains(normalized)
        }?.assetName
    }

    func titleStatusKey(from title: String) -> String? {
        let token = title.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)?.lowercased()
        guard let token else { return nil }
        return assetName(forStatusKey: token) == nil ? nil : token
    }
}
