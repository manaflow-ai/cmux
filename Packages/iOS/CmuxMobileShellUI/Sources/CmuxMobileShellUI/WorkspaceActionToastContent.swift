import Foundation

/// One dismissible workspace-action toast shown at shell scope.
struct WorkspaceActionToastContent: Identifiable, Equatable {
    let id = UUID()
    let message: String
}
