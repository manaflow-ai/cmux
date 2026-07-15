import Foundation

enum MobileWorkspaceInvalidation: Hashable {
    case workspaceGraph
    case workspace(UUID)
    case preview
    case summary

    var metricKind: MobileWorkspaceObserverInvalidationMetricKind {
        switch self {
        case .workspaceGraph: .workspaceGraph
        case .workspace: .workspace
        case .preview: .preview
        case .summary: .summary
        }
    }
}
