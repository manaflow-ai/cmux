import AppKit
import Combine
import Foundation

@MainActor
final class SidebarShortcutHintModifierMonitor: ObservableObject {
    @Published private(set) var isModifierPressed = false

    private weak var hostWindow: NSWindow?
    private var hostWindowDidBecomeKeyObserver: NSObjectProtocol?
    private var hostWindowDidResignKeyObserver: NSObjectProtocol?
    private var flagsMonitor: Any?
    private var keyDownMonitor: Any?
    private var appResignObserver: NSObjectProtocol?
    private var pendingShowWorkItem: DispatchWorkItem?

    func setHostWindow(_ window: NSWindow?) {
        guard hostWindow !== window else { return }
        removeHostWindowObservers()
        hostWindow = window
        guard let window else {
            cancelPendingHintShow(resetVisible: true)
            return
        }

        hostWindowDidBecomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.update(from: NSEvent.modifierFlags, eventWindow: nil)
            }
        }

        hostWindowDidResignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cancelPendingHintShow(resetVisible: true)
            }
        }

        update(from: NSEvent.modifierFlags, eventWindow: nil)
    }

    func start() {
        guard flagsMonitor == nil else {
            update(from: NSEvent.modifierFlags, eventWindow: nil)
            return
        }

        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.update(from: event.modifierFlags, eventWindow: event.window)
            return event
        }

        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
            return event
        }

        appResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cancelPendingHintShow(resetVisible: true)
            }
        }

        update(from: NSEvent.modifierFlags, eventWindow: nil)
    }

    func stop() {
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
        if let appResignObserver {
            NotificationCenter.default.removeObserver(appResignObserver)
            self.appResignObserver = nil
        }
        removeHostWindowObservers()
        cancelPendingHintShow(resetVisible: true)
    }

    private func handleKeyDown(_ event: NSEvent) {
        guard isCurrentWindow(eventWindow: event.window) else { return }
        cancelPendingHintShow(resetVisible: true)
    }

    private func isCurrentWindow(eventWindow: NSWindow?) -> Bool {
        ShortcutHintModifierPolicy.isCurrentWindow(
            hostWindowNumber: hostWindow?.windowNumber,
            hostWindowIsKey: hostWindow?.isKeyWindow ?? false,
            eventWindowNumber: eventWindow?.windowNumber,
            keyWindowNumber: NSApp.keyWindow?.windowNumber
        )
    }

    private func update(from modifierFlags: NSEvent.ModifierFlags, eventWindow: NSWindow?) {
        guard ShortcutHintModifierPolicy.shouldShowHints(
            for: modifierFlags,
            hostWindowNumber: hostWindow?.windowNumber,
            hostWindowIsKey: hostWindow?.isKeyWindow ?? false,
            eventWindowNumber: eventWindow?.windowNumber,
            keyWindowNumber: NSApp.keyWindow?.windowNumber
        ) else {
            cancelPendingHintShow(resetVisible: true)
            return
        }

        queueHintShow()
    }

    private func queueHintShow() {
        guard !isModifierPressed else { return }
        guard pendingShowWorkItem == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingShowWorkItem = nil
            guard ShortcutHintModifierPolicy.shouldShowHints(
                for: NSEvent.modifierFlags,
                hostWindowNumber: self.hostWindow?.windowNumber,
                hostWindowIsKey: self.hostWindow?.isKeyWindow ?? false,
                eventWindowNumber: nil,
                keyWindowNumber: NSApp.keyWindow?.windowNumber
            ) else { return }
            self.isModifierPressed = true
        }

        pendingShowWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + ShortcutHintModifierPolicy.intentionalHoldDelay, execute: workItem)
    }

    private func cancelPendingHintShow(resetVisible: Bool) {
        pendingShowWorkItem?.cancel()
        pendingShowWorkItem = nil
        if resetVisible {
            isModifierPressed = false
        }
    }

    private func removeHostWindowObservers() {
        if let hostWindowDidBecomeKeyObserver {
            NotificationCenter.default.removeObserver(hostWindowDidBecomeKeyObserver)
            self.hostWindowDidBecomeKeyObserver = nil
        }
        if let hostWindowDidResignKeyObserver {
            NotificationCenter.default.removeObserver(hostWindowDidResignKeyObserver)
            self.hostWindowDidResignKeyObserver = nil
        }
    }
}

enum SidebarWorkspaceShortcutHintMetrics {
    private static let measurementFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
    private static let minimumSlotWidth: CGFloat = 28
    private static let horizontalPadding: CGFloat = 12
    private static let lock = NSLock()
    private static var cachedHintWidths: [String: CGFloat] = [:]
    #if DEBUG
    private static var measurementCount = 0
    #endif

    static func slotWidth(label: String?, debugXOffset: Double) -> CGFloat {
        guard let label else { return minimumSlotWidth }
        let positiveDebugInset = max(0, CGFloat(ShortcutHintDebugSettings.clamped(debugXOffset))) + 2
        return max(minimumSlotWidth, hintWidth(for: label) + positiveDebugInset)
    }

    static func hintWidth(for label: String) -> CGFloat {
        lock.lock()
        if let cached = cachedHintWidths[label] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let textWidth = (label as NSString).size(withAttributes: [.font: measurementFont]).width
        let measuredWidth = ceil(textWidth) + horizontalPadding

        lock.lock()
        cachedHintWidths[label] = measuredWidth
        #if DEBUG
        measurementCount += 1
        #endif
        lock.unlock()
        return measuredWidth
    }

    #if DEBUG
    static func resetCacheForTesting() {
        lock.lock()
        cachedHintWidths.removeAll()
        measurementCount = 0
        lock.unlock()
    }

    static func measurementCountForTesting() -> Int {
        lock.lock()
        let count = measurementCount
        lock.unlock()
        return count
    }
    #endif
}
