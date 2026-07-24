import Foundation
@testable import CmuxCommandPalette

@MainActor
final class RecordingCommandPaletteEventMonitorSource: CommandPaletteEventMonitorSource {
    private var handler: ((CommandPalettePointerEvent) -> Void)?
    private(set) var addCount = 0
    private(set) var removeCount = 0

    func addLocalMouseDownMonitor(
        for window: AnyObject,
        handler: @escaping (CommandPalettePointerEvent) -> Void
    ) -> Any? {
        addCount += 1
        self.handler = handler
        return NSObject()
    }

    func removeLocalMonitor(_ monitor: Any) {
        removeCount += 1
        handler = nil
    }

    func send(_ event: CommandPalettePointerEvent) {
        handler?(event)
    }
}
