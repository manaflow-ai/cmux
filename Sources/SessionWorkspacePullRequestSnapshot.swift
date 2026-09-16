import Foundation

/// A pull request explicitly associated with a workspace, independent of any
/// terminal panel's shell-reported metadata.
struct SessionWorkspacePullRequestSnapshot: Codable, Sendable, Equatable {
    var number: Int
    var label: String
    var url: String
    var status: String
    var branch: String?
    var isStale: Bool
}
