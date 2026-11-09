import CmuxNextCompat
import CmuxNextDesign
import Observation

extension AppServices {
    /// Repaints every window when `appearance.borders` changes, so borders set outside layout
    /// (theme hooks, init) and the agent page's theme follow at once (plans/cmux-next/borders.md).
    func observeBorders() {
        borderObservation?.cancel()
        borderObservation = Task {
            var last = Borders.current.mode
            for await mode in ObservationStream({ Borders.current.mode }) where mode != last {
                last = mode
                self.themeStore.repaintAll()
            }
        }
    }
}
