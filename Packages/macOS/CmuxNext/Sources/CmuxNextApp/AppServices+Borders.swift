import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextDesign
import Observation

extension AppServices {
    /// Repaints every window when `appearance.borders` or the agent chat width (Debug Settings)
    /// changes, so borders set outside layout (theme hooks, init) and the agent page's theme follow
    /// at once (plans/cmux-next/borders.md).
    func observeBorders() {
        borderObservation?.cancel()
        borderObservation = Task {
            var last = (Borders.current.mode, AgentPaneTunables.chatWidth.value)
            for await mode in ObservationStream({ (Borders.current.mode, AgentPaneTunables.chatWidth.value) }) where mode != last {
                last = mode
                self.themeStore.repaintAll()
            }
        }
    }
}
