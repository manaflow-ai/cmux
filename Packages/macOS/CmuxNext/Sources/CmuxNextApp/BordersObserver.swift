import CmuxNextDesign
import Observation

/// Keeps border changes made outside layout in sync with every window.
struct BordersObserver {
    let task: Task<Void, Never>

    init() {
        task = Task {
            var last = Borders.current.mode
            for await mode in Observations({ Borders.current.mode }) where mode != last {
                last = mode
                ThemeStore.shared.repaintAll()
            }
        }
    }
}
