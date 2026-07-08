import Foundation

// Short-needle debounce for browser find-in-page. Mirrors the pre-Observation
// Combine pipeline: needles under three characters wait 300ms before firing so
// rapid typing does not thrash the page searcher; longer needles and clears
// fire immediately. The pending task is cancelled on every edit and when the
// find session closes (see the `searchState` observer in `BrowserPanel.swift`).
extension BrowserPanel {
    func scheduleFindSearch(_ needle: String) {
        searchNeedleTask?.cancel()
        searchNeedleTask = nil
        guard !needle.isEmpty, needle.count < 3 else {
            fireFindSearch(needle)
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
            self?.fireFindSearch(needle)
        }
    }

    private func fireFindSearch(_ needle: String) {
#if DEBUG
        cmuxDebugLog("browser.find.needle.updated panel=\(id.uuidString.prefix(5)) bytes=\(needle.lengthOfBytes(using: .utf8))")
#endif
        executeFindSearch(needle)
    }
}
