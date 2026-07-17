import Foundation

enum DockExecutionContext: Hashable, Sendable {
    case local
    case remote(DockRemoteExecutionContext)
}
