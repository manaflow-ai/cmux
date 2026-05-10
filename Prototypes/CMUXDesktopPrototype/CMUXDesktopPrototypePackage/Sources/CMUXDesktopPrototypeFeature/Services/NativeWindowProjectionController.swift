import AppKit
import CoreGraphics

@MainActor
final class NativeWindowProjectionController {
    private let accessibilityController = AccessibilityWindowController()
    private var targetWindow: HostWindow?
    private var targetSlot: NativeWindowSlotFrame?
    private var isPointerInTarget = false
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?

    func start(window: HostWindow) {
        targetWindow = window
        installMouseMonitors()
    }

    func updateWindow(_ window: HostWindow) {
        targetWindow = window
    }

    func stop() {
        removeMouseMonitors()
        targetWindow = nil
        targetSlot = nil
        isPointerInTarget = false
    }

    func place(window: HostWindow, in slot: NativeWindowSlotFrame) -> AccessibilityActionResult {
        targetWindow = window
        targetSlot = slot
        installMouseMonitors()
        isPointerInTarget = slot.cocoaFrame.contains(NSEvent.mouseLocation)
        return accessibilityController.place(window, frame: slot.quartzFrame, raise: isPointerInTarget)
    }

    private func installMouseMonitors() {
        guard globalMouseMonitor == nil, localMouseMonitor == nil else {
            return
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            Task { @MainActor in
                self?.updateFocusForPointer()
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            Task { @MainActor in
                self?.updateFocusForPointer()
            }
            return event
        }
    }

    private func removeMouseMonitors() {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
        }
        globalMouseMonitor = nil
        localMouseMonitor = nil
    }

    private func updateFocusForPointer() {
        guard let targetWindow, let targetSlot else {
            return
        }

        let isInside = targetSlot.cocoaFrame.contains(NSEvent.mouseLocation)
        guard isInside != isPointerInTarget else {
            return
        }

        isPointerInTarget = isInside
        if isInside {
            _ = accessibilityController.raise(targetWindow)
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
