import Foundation

/// The result of decoding a config file while retaining entry-level type
/// findings that do not prevent valid siblings from loading.
struct CmuxConfigDecodedResult: Sendable {
    let config: CmuxConfigFile
    let typeIssues: [CmuxConfigTypeIssue]

    var typeIssueMessage: String? {
        guard !typeIssues.isEmpty else { return nil }
        return typeIssues.map(\.description).joined(separator: "; ")
    }
}
