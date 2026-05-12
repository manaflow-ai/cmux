import Foundation
import CMUXNodeOptions

extension CMUXCLI {
    func mergedNodeOptions(existing: String?, restoreModulePath: String) -> String {
        let requireOption = "--require=\(NodeOptionsSupport.requirePath(restoreModulePath))"
        let memoryOption = "--max-old-space-size=4096"
        let cleanedExisting = cleanedNodeOptions(existing)
        guard !cleanedExisting.isEmpty else {
            return "\(requireOption) \(memoryOption)"
        }
        return "\(requireOption) \(memoryOption) \(cleanedExisting)"
    }

    func normalizedNodeOptionsForRestore(_ existing: String) -> String {
        let tokens = NodeOptionsSupport.tokens(existing)
        let strippedTokens = NodeOptionsSupport.tokensRemovingCmuxRestoreEntries(tokens)
        guard !strippedTokens.isEmpty else { return "" }

        var normalized: [String] = []
        var index = 0
        while index < strippedTokens.count {
            let token = strippedTokens[index]

            if token == "--max-old-space-size", index + 1 < strippedTokens.count {
                normalized.append("--max-old-space-size=\(strippedTokens[index + 1])")
                index += 2
                continue
            }
            normalized.append(token)
            index += 1
        }
        return NodeOptionsSupport.joinedTokens(normalized)
    }

    private func cleanedNodeOptions(_ existing: String?) -> String {
        let tokens = NodeOptionsSupport.tokens(existing)
        let strippedTokens = NodeOptionsSupport.tokensRemovingCmuxRestoreEntries(tokens)
        guard !strippedTokens.isEmpty else { return "" }

        return NodeOptionsSupport.joinedTokens(strippedTokens)
    }
}
