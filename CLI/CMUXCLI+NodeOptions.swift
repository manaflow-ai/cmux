import Foundation
import CMUXNodeOptions

extension CMUXCLI {
    func mergedNodeOptions(existing: String?, restoreModulePath: String) -> String {
        let requireOption = "--require=\(NodeOptionsSupport.requirePath(restoreModulePath))"
        let memoryOption = "--max-old-space-size=4096"
        guard let cleanedExisting = NodeOptionsSupport.sanitizedNodeOptions(existing) else {
            return "\(requireOption) \(memoryOption)"
        }
        return "\(requireOption) \(memoryOption) \(cleanedExisting)"
    }

    func normalizedNodeOptionsForRestore(_ existing: String) -> String? {
        NodeOptionsSupport.normalizedNodeOptionsForRestore(existing)
    }

}
