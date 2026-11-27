import Foundation
import CMUXMobileCore

extension Workspace {
    /// Keeps the originating operation available to synchronous staging calls.
    /// The caller ends this scope with defer; queued requests carry their own copy.
    @MainActor
    func beginTerminalGeometryTransition(_ transition: TerminalWorkContext.Transition) -> @MainActor () -> Void {
        let previous = terminalGeometryTransition
        if previous == .unknown { terminalGeometryTransition = transition }
        let work = TerminalGeometryDiagnostics().begin(
            .geometryPublication, workspaceID: id, transition: terminalGeometryTransition
        )
        return {
            self.terminalGeometryTransition = previous
            work.end()
        }
    }

#if DEBUG
    func debugElapsedMs(since start: TimeInterval) -> String {
        let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
        return String(format: "%.2f", ms)
    }
#endif
}
