import Foundation

/// One request owns its receipt and native reservation until the graph adopts them.
@MainActor
final class CloudWorkspaceCreationOperation {
    let id = UUID()
    let provider: any SurfaceProvider
    let host: CloudWorkspaceCreationHost?
    let terminalRequest = CloudTerminalCreationRequest()
    var receipt: SurfaceWorkspaceCreationReceipt?
    var reservation: CloudTerminalPaneReservation?
    var terminal: SurfaceResource?
    var terminalCursor: CloudVMCursor?
    var isComplete = false

    init(provider: any SurfaceProvider, host: CloudWorkspaceCreationHost?) {
        self.provider = provider
        self.host = host
    }

    var machine: SurfaceMachineID { provider.machine }

    func isConfirmed(in state: CloudVMState) -> Bool {
        guard let receipt, let terminal, state.workspaceIDs.contains(receipt.workspace.id),
              state.lookupIndex.terminal(id: terminal.id.key) != nil else { return false }
        if let cursor = terminalCursor ?? receipt.cursor {
            guard let accepted = state.cursor, accepted.generation == cursor.generation,
                  accepted.revision >= cursor.revision else { return false }
        }
        return terminal.remoteViews?.first.map { state.lookupIndex.tab(id: $0.tabID) != nil } ?? true
    }
}
