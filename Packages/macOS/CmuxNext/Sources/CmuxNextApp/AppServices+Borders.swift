import CmuxNextCompat
import CmuxNextDesign
import Observation

extension AppServices {
    /// Repaints every window when `appearance.borders` or the separate chrome shade changes, so borders set outside layout (theme
    /// hooks, init), the agent page's theme and Settings' `--cmux-sidebar-surface` follow at once (plans/cmux-next/borders.md).
    func observeBorders() {
        borderObservation?.cancel()
        borderObservation = Task {
            var last = WebTheme.pushInputs
            for await inputs in ObservationStream({ WebTheme.pushInputs }) where inputs != last {
                last = inputs
                self.themeStore.repaintAll()
            }
        }
    }
}
