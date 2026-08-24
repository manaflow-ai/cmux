import AppKit
import SwiftUI
import Testing
@testable import CmuxCommandPalette

@MainActor
@Suite("CommandPaletteInteractionMonitor")
struct CommandPaletteInteractionMonitorTests {
    @Test("pointer dismissal requires known-outside panel geometry")
    func pointerDismissalPolicy() {
        let observedWindowEvent = CommandPalettePointerEvent(
            isInObservedWindow: true,
            locationInWindow: CGPoint(x: 20, y: 20)
        )
        let otherWindowEvent = CommandPalettePointerEvent(
            isInObservedWindow: false,
            locationInWindow: CGPoint(x: 20, y: 20)
        )

        #expect(!observedWindowEvent.shouldDismissPalette(panelContainsPoint: true))
        #expect(!observedWindowEvent.shouldDismissPalette(panelContainsPoint: nil))
        #expect(observedWindowEvent.shouldDismissPalette(panelContainsPoint: false))
        #expect(otherWindowEvent.shouldDismissPalette(panelContainsPoint: true))
        #expect(otherWindowEvent.shouldDismissPalette(panelContainsPoint: nil))
    }

    @Test("AppKit monitor keeps inside clicks and exposes the underlying view for outside clicks")
    func appKitMonitorRoutesInsideAndOutsideClicks() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let underlyingView = RecordingMouseDownView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = underlyingView
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        let overlayView = RecordingMouseDownView(frame: underlyingView.bounds)
        overlayView.autoresizingMask = [.width, .height]
        underlyingView.addSubview(overlayView)

        let panelFrame = NSRect(x: 100, y: 100, width: 200, height: 100)
        let panelMarker = NSHostingView(rootView: CommandPalettePanelHitRegion())
        panelMarker.frame = panelFrame
        overlayView.addSubview(panelMarker)
        overlayView.layoutSubtreeIfNeeded()
        let panelCenter = NSPoint(x: panelFrame.midX, y: panelFrame.midY)

        #expect(overlayView.commandPalettePanelContains(windowPoint: panelCenter) == true)
        #expect(overlayView.commandPalettePanelContains(windowPoint: NSPoint(x: 20, y: 20)) == false)
        #expect(NSView().commandPalettePanelContains(windowPoint: .zero) == nil)
        let unlaidOutHost = NSView()
        let unlaidOutMarker = CommandPalettePanelHitRegionView(frame: .zero)
        unlaidOutMarker.identifier = CommandPalettePanelHitRegionView.interfaceIdentifier
        unlaidOutHost.addSubview(unlaidOutMarker)
        #expect(unlaidOutHost.commandPalettePanelContains(windowPoint: .zero) == nil)

        let monitor = CommandPaletteInteractionMonitor()
        var dismissCount = 0
        monitor.activate(
            for: window,
            shouldDismiss: { event in
                event.shouldDismissPalette(
                    panelContainsPoint: overlayView.commandPalettePanelContains(
                        windowPoint: event.locationInWindow
                    )
                )
            },
            onWindowStateChange: {},
            onDismiss: { dismissal in
                #expect(dismissal == .pointer(CommandPalettePointerEvent(
                    isInObservedWindow: true,
                    locationInWindow: NSPoint(x: 20, y: 20)
                )))
                dismissCount += 1
                overlayView.removeFromSuperview()
            }
        )
        defer { monitor.deactivate() }

        NSApp.sendEvent(try mouseDownEvent(at: panelCenter, in: window))
        #expect(dismissCount == 0)
        #expect(overlayView.mouseDownCount == 1)
        #expect(underlyingView.mouseDownCount == 0)

        NSApp.sendEvent(try mouseDownEvent(at: NSPoint(x: 20, y: 20), in: window))
        #expect(dismissCount == 1)
        #expect(underlyingView.mouseDownCount == 1)
    }

    private func mouseDownEvent(at location: NSPoint, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
    }

    @Test("outside mouse-down dismisses and lifecycle cleanup removes every observer")
    func outsideMouseDownDismissesAndCleansUp() {
        let notificationCenter = RecordingCommandPaletteNotificationCenter()
        let eventSource = RecordingCommandPaletteEventMonitorSource()
        let mainMenu = NSMenu()
        let appMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        let monitor = CommandPaletteInteractionMonitor(
            notificationCenter: notificationCenter,
            eventSource: eventSource,
            mainMenuProvider: { mainMenu }
        )
        let window = NSObject()

        var dismissals: [CommandPaletteInteractionDismissal] = []
        var windowStateChangeCount = 0
        monitor.activate(
            for: window,
            shouldDismiss: { _ in true },
            onWindowStateChange: { windowStateChangeCount += 1 },
            onDismiss: { dismissals.append($0) }
        )

        #expect(eventSource.addCount == 1)
        #expect(notificationCenter.addedObservers.map { $0.name } == [
            CommandPaletteInteractionMonitor.windowDidBecomeKeyNotification,
            CommandPaletteInteractionMonitor.windowDidResignKeyNotification,
            CommandPaletteInteractionMonitor.menuDidBeginTrackingNotification,
        ])

        eventSource.send(CommandPalettePointerEvent(
            isInObservedWindow: true,
            locationInWindow: CGPoint(x: 20, y: 20)
        ))
        #expect(dismissals == [.pointer(CommandPalettePointerEvent(
            isInObservedWindow: true,
            locationInWindow: CGPoint(x: 20, y: 20)
        ))])

        notificationCenter.send(
            name: CommandPaletteInteractionMonitor.windowDidBecomeKeyNotification,
            object: window
        )
        #expect(windowStateChangeCount == 1)
        notificationCenter.send(
            name: CommandPaletteInteractionMonitor.windowDidResignKeyNotification,
            object: window
        )
        #expect(windowStateChangeCount == 2)
        #expect(dismissals == [
            .pointer(CommandPalettePointerEvent(
                isInObservedWindow: true,
                locationInWindow: CGPoint(x: 20, y: 20)
            )),
            .windowResignedKey,
        ])

        notificationCenter.send(
            name: CommandPaletteInteractionMonitor.menuDidBeginTrackingNotification,
            object: NSMenu()
        )
        #expect(dismissals.count == 2)
        notificationCenter.send(
            name: CommandPaletteInteractionMonitor.menuDidBeginTrackingNotification,
            object: appMenu
        )
        #expect(dismissals.last == .mainMenuBeganTracking)

        monitor.deactivate()
        #expect(eventSource.removeCount == 1)
        #expect(
            notificationCenter.removedObserverIDs == notificationCenter.addedObservers.map { $0.token.id }
        )
    }

    @Test("re-activation refreshes callbacks without duplicating monitors")
    func reactivationRefreshesCallbacks() {
        let eventSource = RecordingCommandPaletteEventMonitorSource()
        let monitor = CommandPaletteInteractionMonitor(
            notificationCenter: RecordingCommandPaletteNotificationCenter(),
            eventSource: eventSource
        )
        let window = NSObject()

        var firstDismissCount = 0
        var secondDismissCount = 0
        monitor.activate(
            for: window,
            shouldDismiss: { _ in true },
            onWindowStateChange: {},
            onDismiss: { _ in firstDismissCount += 1 }
        )
        monitor.activate(
            for: window,
            shouldDismiss: { _ in true },
            onWindowStateChange: {},
            onDismiss: { _ in secondDismissCount += 1 }
        )

        eventSource.send(CommandPalettePointerEvent(isInObservedWindow: true, locationInWindow: .zero))

        #expect(eventSource.addCount == 1)
        #expect(firstDismissCount == 0)
        #expect(secondDismissCount == 1)
    }

    @Test("deinit removes pointer and key-window observation")
    func deinitRemovesObservation() {
        let notificationCenter = RecordingCommandPaletteNotificationCenter()
        let eventSource = RecordingCommandPaletteEventMonitorSource()
        var monitor: CommandPaletteInteractionMonitor? = CommandPaletteInteractionMonitor(
            notificationCenter: notificationCenter,
            eventSource: eventSource
        )
        let window = NSObject()
        monitor?.activate(
            for: window,
            shouldDismiss: { _ in false },
            onWindowStateChange: {},
            onDismiss: { _ in }
        )

        weak let weakMonitor = monitor
        monitor = nil

        #expect(weakMonitor == nil)
        #expect(eventSource.removeCount == 1)
        #expect(
            notificationCenter.removedObserverIDs == notificationCenter.addedObservers.map { $0.token.id }
        )
    }
}
