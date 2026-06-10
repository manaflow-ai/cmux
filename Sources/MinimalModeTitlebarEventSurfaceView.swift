import AppKit
import Bonsplit
import SwiftUI


// MARK: - Minimal-mode titlebar event surface view
enum WindowMouseMovedEventsCoordinator {
    private struct Record {
        weak var window: NSWindow?
        let previousValue: Bool
        var owners: Set<ObjectIdentifier>
    }

    private nonisolated(unsafe) static var records: [ObjectIdentifier: Record] = [:]
    private nonisolated static let lock = NSLock()

    static func enable(for window: NSWindow, owner: AnyObject) {
        lock.lock()
        defer { lock.unlock() }

        let windowKey = ObjectIdentifier(window)
        let ownerKey = ObjectIdentifier(owner)
        if var record = records[windowKey] {
            record.owners.insert(ownerKey)
            records[windowKey] = record
        } else {
            records[windowKey] = Record(
                window: window,
                previousValue: window.acceptsMouseMovedEvents,
                owners: [ownerKey]
            )
        }
        window.acceptsMouseMovedEvents = true
    }

    static func disable(for window: NSWindow, owner: AnyObject) {
        lock.lock()
        defer { lock.unlock() }

        let windowKey = ObjectIdentifier(window)
        guard var record = records[windowKey] else { return }
        record.owners.remove(ObjectIdentifier(owner))
        if record.owners.isEmpty {
            record.window?.acceptsMouseMovedEvents = record.previousValue
            records.removeValue(forKey: windowKey)
        } else {
            records[windowKey] = record
        }
    }

    static func disableOwner(_ owner: AnyObject) {
        lock.lock()
        defer { lock.unlock() }

        let ownerKey = ObjectIdentifier(owner)
        for windowKey in Array(records.keys) {
            guard var record = records[windowKey] else { continue }
            record.owners.remove(ownerKey)
            if record.owners.isEmpty {
                record.window?.acceptsMouseMovedEvents = record.previousValue
                records.removeValue(forKey: windowKey)
            } else {
                records[windowKey] = record
            }
        }
    }
}

struct MinimalModeTitlebarEventSurfaceView: NSViewRepresentable {
    var isEnabled: Bool

    private final class PassthroughView: NSView {
        var isEnabled = false
        private weak var mouseMovedWindow: NSWindow?
        private var isTrackingMouseMovedEvents = false
        private var titlebarClickMonitor: Any?
        private var lastTitlebarClick: MinimalModeTitlebarClickRecord?

        deinit {
            stopMouseMovedTracking()
            stopTitlebarClickMonitor()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            refreshMouseMovedTracking()
            refreshTitlebarClickMonitor()
        }

        func refreshMouseMovedTracking() {
            guard isEnabled, let window else {
                stopMouseMovedTracking()
                stopTitlebarClickMonitor()
                return
            }
            guard !isTrackingMouseMovedEvents || mouseMovedWindow !== window else { return }
            stopMouseMovedTracking()
            WindowMouseMovedEventsCoordinator.enable(for: window, owner: self)
            mouseMovedWindow = window
            isTrackingMouseMovedEvents = true
            refreshTitlebarClickMonitor()
        }

        private func stopMouseMovedTracking() {
            if let mouseMovedWindow {
                WindowMouseMovedEventsCoordinator.disable(for: mouseMovedWindow, owner: self)
            } else {
                WindowMouseMovedEventsCoordinator.disableOwner(self)
            }
            mouseMovedWindow = nil
            isTrackingMouseMovedEvents = false
        }

        private func refreshTitlebarClickMonitor() {
            guard isEnabled, window != nil else {
                stopTitlebarClickMonitor()
                return
            }
            guard titlebarClickMonitor == nil else { return }
            titlebarClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                self?.handleTitlebarMouseDown(event) ?? event
            }
        }

        private func stopTitlebarClickMonitor() {
            if let titlebarClickMonitor {
                NSEvent.removeMonitor(titlebarClickMonitor)
            }
            titlebarClickMonitor = nil
            lastTitlebarClick = nil
        }

        private func handleTitlebarMouseDown(_ event: NSEvent) -> NSEvent? {
            guard isEnabled, let window else { return event }
            guard let locationInWindow = locationInWindow(for: event, window: window) else {
                lastTitlebarClick = nil
                return event
            }
            let contentBounds = window.contentView?.bounds ?? NSRect(
                x: 0,
                y: 0,
                width: window.frame.width,
                height: window.frame.height
            )
            guard isMinimalModeWindowTitlebarClickCandidate(
                isMinimalMode: WorkspacePresentationModeSettings.isMinimal(),
                isFullScreen: window.styleMask.contains(.fullScreen),
                isMainWindow: isMainWorkspaceWindow(window),
                locationInWindow: locationInWindow,
                contentBounds: contentBounds,
                titlebarBandHeight: minimalModeTitlebarDoubleClickBandHeight(for: window)
            ) else {
                lastTitlebarClick = nil
                return event
            }
            guard !isMinimalModeTitlebarControlHit(window: window, locationInWindow: locationInWindow) else {
                lastTitlebarClick = nil
                return event
            }

            #if DEBUG
            if ProcessInfo.processInfo.environment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP"] == "1" {
                _ = CmuxUITestCapture.mutateJSONObjectIfConfigured(envKey: "CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH") { payload in
                    let count = (payload["minimalTitlebarEventSurfaceMouseDownCount"] as? String).flatMap(Int.init) ?? 0
                    payload["minimalTitlebarEventSurfaceMouseDownCount"] = String(count + 1)
                    payload["minimalTitlebarEventSurfaceLastPoint"] = windowDragHandleFormatPoint(locationInWindow)
                    payload["minimalTitlebarEventSurfaceLastClickCount"] = String(event.clickCount)
                }
            }
            #endif

            let isDoubleClick = minimalModeTitlebarClickFormsDoubleClick(
                clickCount: event.clickCount,
                timestamp: event.timestamp,
                locationInWindow: locationInWindow,
                windowNumber: window.windowNumber,
                previous: lastTitlebarClick,
                doubleClickInterval: NSEvent.doubleClickInterval,
                doubleClickIntervalTolerance: minimalModeTitlebarSyntheticDoubleClickTolerance
            )
            guard isDoubleClick else {
                lastTitlebarClick = MinimalModeTitlebarClickRecord(
                    windowNumber: window.windowNumber,
                    timestamp: event.timestamp,
                    locationInWindow: locationInWindow
                )
                return event
            }
            lastTitlebarClick = nil
            let result = handleTitlebarDoubleClick(window: window, behavior: .standardAction)
            return result.consumesEvent ? nil : event
        }

        private func locationInWindow(for event: NSEvent, window: NSWindow) -> NSPoint? {
            if event.window === window {
                return event.locationInWindow
            }
            guard event.window == nil else { return nil }
            let screenPoint = NSEvent.mouseLocation
            guard window.frame.insetBy(dx: -1, dy: -1).contains(screenPoint) else { return nil }
            return window.convertFromScreen(NSRect(origin: screenPoint, size: .zero)).origin
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView(frame: .zero)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.isEnabled = isEnabled
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? PassthroughView else { return }
        view.isEnabled = isEnabled
        view.refreshMouseMovedTracking()
    }
}
