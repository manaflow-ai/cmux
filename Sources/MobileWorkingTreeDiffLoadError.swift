import Foundation

/// Stable RPC error details produced while loading a mobile working-tree diff.
struct MobileWorkingTreeDiffLoadError: Error {
    let code: String
    let message: String
}
