import Foundation

/// One request owns its receipt and native reservation until the graph adopts them.
@MainActor
final class CloudWorkspaceCreationOperation {
    let id = UUID()
    let provider: any SurfaceProvider
    let host: CloudWorkspaceCreationHost?
    let allowsActionRetry: Bool
    let terminalRequest = CloudTerminalCreationRequest()
    var receipt: SurfaceWorkspaceCreationReceipt?
    var reservation: CloudTerminalPaneReservation?
    var terminal: SurfaceResource?
    var terminalCursor: CloudVMCursor?
    var isComplete = false
    var isRunning = false
    var failure: Error?
    var retryTask: Task<Void, Never>?

    init(provider: any SurfaceProvider, host: CloudWorkspaceCreationHost?, allowsActionRetry: Bool) {
        self.provider = provider
        self.host = host
        self.allowsActionRetry = allowsActionRetry
    }

    var machine: SurfaceMachineID { provider.machine }

    func isConfirmed(in state: CloudVMState) -> Bool {
        guard let receipt, let terminal, state.workspaceIDs.contains(receipt.workspace.id),
              state.lookupIndex.terminal(id: terminal.id.key) != nil else { return false }
        if let cursor = terminalCursor ?? receipt.cursor {
            guard let accepted = state.cursor, accepted.generation == cursor.generation,
                  accepted.revision >= cursor.revision else { return false }
        }
        return containsStarter(in: state)
    }

    func containsStarter(in state: CloudVMState) -> Bool {
        guard let terminal, state.lookupIndex.terminal(id: terminal.id.key) != nil else { return false }
        guard let view = terminal.remoteViews?.first(where: { $0.workspace.id == receipt?.workspace.id }) else { return true }
        guard let tab = state.lookupIndex.tab(id: view.tabID),
              tab.contentKind == terminal.kind.rawValue, tab.contentID == terminal.id.key,
              let pane = state.lookupIndex.pane(id: tab.paneID),
              let screen = state.lookupIndex.screen(id: pane.screenID) else { return false }
        return screen.workspaceID == receipt?.workspace.id
    }

}
