import Foundation

@MainActor
final class BrowserHiddenWebViewMemoryPressureResponder: MemoryPressureResponder {
    let memoryPressureResponderID = "browser-hidden-webviews"
    let memoryPressureMinimumSeverity: MemoryPressureSeverity = .warning
    let memoryPressurePriority = 90

    private let browserPanels: @MainActor () -> [BrowserPanel]

    init(browserPanels: @escaping @MainActor () -> [BrowserPanel]) {
        self.browserPanels = browserPanels
    }

    func shedMemory(for snapshot: MemoryPressureSnapshot) -> MemoryPressureShedResult {
        let discardedCount = browserPanels().reduce(0) { count, panel in
            panel.discardHiddenWebViewForSystemMemoryPressure(now: snapshot.sampledAt) ? count + 1 : count
        }
        return MemoryPressureShedResult(
            reclaimedItemCount: discardedCount,
            detail: "hidden-browser-webviews"
        )
    }
}
