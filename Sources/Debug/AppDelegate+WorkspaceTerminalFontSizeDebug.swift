#if DEBUG
extension AppDelegate {
    func debugFlushPendingWorkspaceTerminalFontSizeChanges() {
        for context in mainWindowContexts.values {
            context.workspaceTerminalFontSizeCoordinator.debugFlushOneDrain()
        }
    }

    func debugDrainAllPendingWorkspaceTerminalFontSizeChanges() {
        for context in mainWindowContexts.values {
            context.workspaceTerminalFontSizeCoordinator.debugDrainAll()
        }
    }

    var debugPendingWorkspaceTerminalFontSizeChangeCount: Int {
        mainWindowContexts.values.reduce(into: 0) {
            $0 += $1.workspaceTerminalFontSizeCoordinator
                .debugPendingRequestCount
        }
    }
}
#endif
