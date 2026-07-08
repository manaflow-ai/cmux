import Foundation
internal import CMUXDebugLog

// Short-needle debounce for terminal find. Mirrors the pre-Observation Combine
// pipeline: needles under three characters wait 300ms before firing so rapid
// typing does not thrash the searcher; longer needles and clears fire
// immediately. The pending task is cancelled on every edit and when the find
// session closes (see the `searchState` observer in `TerminalSurface.swift`).
extension TerminalSurface {
    @MainActor
    func scheduleSearchNeedle(_ needle: String) {
        searchNeedleTask?.cancel()
        searchNeedleTask = nil
        guard !needle.isEmpty, needle.count < 3 else {
            fireSearchNeedle(needle)
            return
        }

        searchNeedleTask = Task { @MainActor [weak self] in
            do {
                // Intentional bounded debounce; cancelled on every edit/close.
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.fireSearchNeedle(needle)
        }
    }

    @MainActor
    private func fireSearchNeedle(_ needle: String) {
#if DEBUG
        logDebugEvent("find.needle updated tab=\(tabId.uuidString.prefix(5)) surface=\(id.uuidString.prefix(5)) chars=\(needle.count)")
#endif
        _ = performBindingAction("search:\(needle)")
    }
}
