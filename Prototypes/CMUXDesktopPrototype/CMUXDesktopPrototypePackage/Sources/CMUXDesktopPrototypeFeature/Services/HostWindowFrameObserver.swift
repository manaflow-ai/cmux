import ApplicationServices
import CoreGraphics

@MainActor
final class HostWindowFrameObserver {
    private let accessibilityController = AccessibilityWindowController()
    private var observer: AXObserver?
    private var observedWindow: AXUIElement?
    private var onFrameChanged: ((CGRect) -> Void)?

    func start(window: HostWindow, onFrameChanged: @escaping (CGRect) -> Void) -> AccessibilityActionResult {
        stop()

        guard accessibilityController.isTrusted else {
            return .accessibilityPermissionMissing
        }
        guard let axWindow = accessibilityController.resolvedWindow(for: window) else {
            return .windowUnavailable
        }

        var newObserver: AXObserver?
        let createResult = AXObserverCreate(window.ownerPID, hostWindowFrameObserverCallback, &newObserver)
        guard createResult == .success, let newObserver else {
            return .failed(createResult)
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let notifications = [
            kAXMovedNotification,
            kAXResizedNotification,
            kAXUIElementDestroyedNotification,
        ]

        for notification in notifications {
            _ = AXObserverAddNotification(newObserver, axWindow, notification as CFString, refcon)
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .commonModes)
        self.observer = newObserver
        self.observedWindow = axWindow
        self.onFrameChanged = onFrameChanged
        publishFrame(for: axWindow)
        return .succeeded
    }

    func stop() {
        if let observer, let observedWindow {
            for notification in [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification] {
                AXObserverRemoveNotification(observer, observedWindow, notification as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }

        observer = nil
        observedWindow = nil
        onFrameChanged = nil
    }

    fileprivate func publishFrame(for element: AXUIElement) {
        guard let frame = accessibilityController.frame(of: element) else {
            return
        }
        onFrameChanged?(frame)
    }

    fileprivate func publishObservedFrame() {
        guard let observedWindow else {
            return
        }
        publishFrame(for: observedWindow)
    }
}

private let hostWindowFrameObserverCallback: AXObserverCallback = { _, _, _, refcon in
    guard let refcon else {
        return
    }

    let observer = Unmanaged<HostWindowFrameObserver>.fromOpaque(refcon).takeUnretainedValue()
    Task { @MainActor in
        observer.publishObservedFrame()
    }
}
