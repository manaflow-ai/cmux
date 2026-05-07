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
        guard !tokens.isEmpty else { return "" }

        var normalized: [String] = []
        var index = 0
        var shouldDropInjectedHeapCap = false
        while index < tokens.count {
            let token = tokens[index]

            if shouldDropInjectedHeapCap, NodeOptionsSupport.isInjectedNodeHeapCap(tokens, index: index) {
                index += NodeOptionsSupport.nodeHeapCapWidth(tokens, index: index)
                shouldDropInjectedHeapCap = false
                continue
            }
            shouldDropInjectedHeapCap = false

            if NodeOptionsSupport.isRequireOption(token), index + 1 < tokens.count,
               NodeOptionsSupport.isCmuxRestoreModulePath(tokens[index + 1]) {
                index += 2
                shouldDropInjectedHeapCap = true
                continue
            }
            if let path = NodeOptionsSupport.inlineRequireOptionPath(token),
               NodeOptionsSupport.isCmuxRestoreModulePath(path) {
                index += 1
                shouldDropInjectedHeapCap = true
                continue
            }

            if token == "--max-old-space-size", index + 1 < tokens.count {
                normalized.append("--max-old-space-size=\(tokens[index + 1])")
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
        guard !tokens.isEmpty else { return "" }

        var filtered: [String] = []
        var index = 0
        var shouldDropInjectedHeapCap = false
        while index < tokens.count {
            let token = tokens[index]

            if shouldDropInjectedHeapCap, NodeOptionsSupport.isInjectedNodeHeapCap(tokens, index: index) {
                index += NodeOptionsSupport.nodeHeapCapWidth(tokens, index: index)
                shouldDropInjectedHeapCap = false
                continue
            }
            shouldDropInjectedHeapCap = false

            if NodeOptionsSupport.isRequireOption(token), index + 1 < tokens.count,
               NodeOptionsSupport.isCmuxRestoreModulePath(tokens[index + 1]) {
                index += 2
                shouldDropInjectedHeapCap = true
                continue
            }
            if let path = NodeOptionsSupport.inlineRequireOptionPath(token),
               NodeOptionsSupport.isCmuxRestoreModulePath(path) {
                index += 1
                shouldDropInjectedHeapCap = true
                continue
            }

            filtered.append(token)
            index += 1
        }
        return NodeOptionsSupport.joinedTokens(filtered)
    }
}
