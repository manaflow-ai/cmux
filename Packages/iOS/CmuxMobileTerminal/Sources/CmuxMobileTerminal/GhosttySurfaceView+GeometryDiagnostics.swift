#if canImport(UIKit)
import CMUXMobileCore

extension GhosttySurfaceView {
    /// Captures only fixed categories and counts before crossing to the surface queue.
    func terminalWorkSnapshot(transition: TerminalWorkContext.Transition) -> TerminalWorkContext {
        .init(
            transition: transition,
            population: terminalWorkPopulation.population,
            workspaceCount: terminalWorkPopulation.workspaceCount,
            surfaceCount: terminalWorkPopulation.surfaceCount
        )
    }
}
#endif
