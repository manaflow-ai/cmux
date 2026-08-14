import Foundation

@MainActor
final class BrowserHiddenWebViewMemoryPressureResponder: MemoryPressureResponder {
    let memoryPressureResponderID = "browser-hidden-webviews"
    let memoryPressureMinimumSeverity: MemoryPressureSeverity = .warning
    let memoryPressurePriority = 90

    private let tabManagers: @MainActor () -> [TabManager]

    init(tabManagers: @escaping @MainActor () -> [TabManager]) {
        self.tabManagers = tabManagers
    }

    func shedMemory(for snapshot: MemoryPressureSnapshot) -> MemoryPressureShedResult {
        let discardedCount = tabManagers().reduce(0) { count, manager in
            count + manager.discardHiddenBrowserWebViewsForSystemMemoryPressure(
                now: snapshot.sampledAt
            )
        }
        return MemoryPressureShedResult(
            reclaimedItemCount: discardedCount,
            detail: "hidden-browser-webviews"
        )
    }
}
