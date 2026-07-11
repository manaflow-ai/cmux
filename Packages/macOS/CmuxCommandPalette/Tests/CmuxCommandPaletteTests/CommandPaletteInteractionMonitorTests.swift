import AppKit
import Foundation
import Testing
@testable import CmuxCommandPalette

@MainActor
@Suite("CommandPaletteInteractionMonitor")
struct CommandPaletteInteractionMonitorTests {
    @Test("outside mouse-down dismisses and lifecycle cleanup removes every observer")
    func outsideMouseDownDismissesAndCleansUp() throws {
        let notificationCenter = RecordingCommandPaletteNotificationCenter()
        let eventSource = RecordingCommandPaletteEventMonitorSource()
        let monitor = CommandPaletteInteractionMonitor(
            notificationCenter: notificationCenter,
            eventSource: eventSource
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.close() }

        var dismissCount = 0
        var windowStateChangeCount = 0
        monitor.activate(
            for: window,
            shouldDismiss: { _ in true },
            onWindowStateChange: { windowStateChangeCount += 1 },
            onDismiss: { dismissCount += 1 }
        )

        #expect(eventSource.addCount == 1)
        #expect(notificationCenter.addedObservers.map(\.name) == [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
        ])

        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 20, y: 20),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        #expect(eventSource.send(event) === event)
        #expect(dismissCount == 1)

        notificationCenter.post(name: NSWindow.didBecomeKeyNotification, object: window)
        #expect(windowStateChangeCount == 1)
        notificationCenter.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(windowStateChangeCount == 2)
        #expect(dismissCount == 2)

        monitor.deactivate()
        #expect(eventSource.removeCount == 1)
        #expect(
            notificationCenter.removedObserverIDs == notificationCenter.addedObservers.map(\.token.id)
        )
    }

    @Test("re-activation refreshes callbacks without duplicating monitors")
    func reactivationRefreshesCallbacks() throws {
        let eventSource = RecordingCommandPaletteEventMonitorSource()
        let monitor = CommandPaletteInteractionMonitor(
            notificationCenter: RecordingCommandPaletteNotificationCenter(),
            eventSource: eventSource
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.close() }

        var firstDismissCount = 0
        var secondDismissCount = 0
        monitor.activate(
            for: window,
            shouldDismiss: { _ in true },
            onWindowStateChange: {},
            onDismiss: { firstDismissCount += 1 }
        )
        monitor.activate(
            for: window,
            shouldDismiss: { _ in true },
            onWindowStateChange: {},
            onDismiss: { secondDismissCount += 1 }
        )

        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 1
        ))
        _ = eventSource.send(event)

        #expect(eventSource.addCount == 1)
        #expect(firstDismissCount == 0)
        #expect(secondDismissCount == 1)
    }
}

@MainActor
private final class RecordingCommandPaletteEventMonitorSource: CommandPaletteEventMonitorSource {
    private var handler: ((NSEvent) -> NSEvent?)?
    private(set) var addCount = 0
    private(set) var removeCount = 0

    func addLocalMouseDownMonitor(
        handler: @escaping (NSEvent) -> NSEvent?
    ) -> Any {
        addCount += 1
        self.handler = handler
        return NSObject()
    }

    func removeLocalMonitor(_ monitor: Any) {
        removeCount += 1
        handler = nil
    }

    func send(_ event: NSEvent) -> NSEvent? {
        handler?(event)
    }
}

private final class RecordingCommandPaletteObserverToken: NSObject {
    let id: Int

    init(id: Int) {
        self.id = id
        super.init()
    }
}

private final class RecordingCommandPaletteNotificationCenter: NotificationCenter, @unchecked Sendable {
    struct AddedObserver {
        let name: Notification.Name?
        weak var object: AnyObject?
        let token: RecordingCommandPaletteObserverToken
    }

    private(set) var addedObservers: [AddedObserver] = []
    private(set) var removedObserverIDs: [Int] = []

    override func addObserver(
        forName name: Notification.Name?,
        object obj: Any?,
        queue: OperationQueue?,
        using block: @escaping @Sendable (Notification) -> Void
    ) -> any NSObjectProtocol {
        let token = RecordingCommandPaletteObserverToken(id: addedObservers.count + 1)
        addedObservers.append(AddedObserver(name: name, object: obj as AnyObject?, token: token))
        return token
    }

    override func removeObserver(_ observer: Any) {
        guard let token = observer as? RecordingCommandPaletteObserverToken else { return }
        removedObserverIDs.append(token.id)
    }
}
