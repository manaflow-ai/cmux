import CmuxNextDesign
import Observation

extension AppServices {
    /// Repaints every window when `appearance.borders` changes (cmux.json or
    /// the Debug Settings override), so borders set outside layout (theme
    /// hooks, init) follow at once (plans/cmux-next/borders.md).
    func observeBorders() {
        borderObservation?.cancel()
        borderObservation = Task {
            var last = Borders.current.mode
            for await mode in Observations({ Borders.current.mode }) where mode != last {
                last = mode
                ThemeStore.shared.repaintAll()
            }
        }
    }
}
