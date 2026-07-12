import Foundation

/// Sendable working-tree diff data before conversion to the JSON RPC envelope.
struct MobileWorkingTreeDiffPayload: Sendable {
    let patch: String
    let repositoryRoot: String
    let title: String

    var rpcValue: [String: Any] {
        [
            "patch": patch,
            "repository_root": repositoryRoot,
            "title": title,
        ]
    }
}
