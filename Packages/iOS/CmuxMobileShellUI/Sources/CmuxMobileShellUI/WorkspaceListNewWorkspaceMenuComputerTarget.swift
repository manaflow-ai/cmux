import SwiftUI

extension WorkspaceListNewWorkspaceMenuValue {
    /// A computer that can receive a new workspace from the shared list menu.
    struct ComputerTarget: Equatable, Identifiable {
        let id: String
        let kind: Kind
        let name: String
        let isConnected: Bool
        let systemImage: String

        var statusColor: Color {
            isConnected ? .green : .secondary
        }
    }
}
