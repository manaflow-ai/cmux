import AppKit
import Observation

@MainActor
@Observable
final class WindowScopedShortcutHintModifierMonitor {
    private(set) var isModifierPressed = false

    private let activation: ShortcutHintModifierActivation
    private let allowsHintsForWindow: (NSWindow) -> Bool
    @ObservationIgnored private weak var hostWindow: NSWindow?
    @ObservationIgnored private var hostWindowDidBecomeKeyObserver: NSObjectProtocol?
    @ObservationIgnored private var hostWindowDidResignKeyObserver: NSObjectProtocol?
    @ObservationIgnored private var flagsMonitor: Any?
    @ObservationIgnored private var keyDownMonitor: Any?
    @ObservationIgnored private var appResignObserver: NSObjectProtocol?
    @ObservationIgnored private var pendingShowWorkItem: DispatchWorkItem?

    private var hasHostWindowObservers: Bool {
        hostWindowDidBecomeKeyObserver != nil && hostWindowDidResignKeyObserver != nil
    }

    init(
        activation: ShortcutHintModifierActivation = .commandOrControl,
        allowsHintsForWindow: @escaping (NSWindow) -> Bool = { _ in true }
    ) {
        self.activation = activation
        self.allowsHintsForWindow = allowsHintsForWindow
    }

    func setHostWindow(_ window: NSWindow?) {
        guard hostWindow !== window || !hasHostWindowObservers else { return }
        removeHostWindowObservers()
        hostWindow = window
        guard let window else {
            cancelPendingHintShow(resetVisible: true)
            return
        }

        installHostWindowObservers(for: window)
        update(from: NSEvent.modifierFlags, eventWindow: nil)
    }

    func start() {
        reinstallHostWindowObserversIfNeeded()

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
        guard let hostWindow,
              isCurrentWindow(eventWindow: eventWindow),
              allowsHintsForWindow(hostWindow),
              activation.shouldShowHints(for: modifierFlags) else {
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
            guard let hostWindow = self.hostWindow,
                  self.isCurrentWindow(eventWindow: nil),
                  self.allowsHintsForWindow(hostWindow),
                  self.activation.shouldShowHints(for: NSEvent.modifierFlags) else {
                return
            }
            self.isModifierPressed = true
        }

        pendingShowWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + ShortcutHintModifierPolicy.intentionalHoldDelay, execute: workItem)
    }

    private func cancelPendingHintShow(resetVisible: Bool) {
        pendingShowWorkItem?.cancel()
        pendingShowWorkItem = nil
        if resetVisible, isModifierPressed {
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

    private func reinstallHostWindowObserversIfNeeded() {
        guard let hostWindow, !hasHostWindowObservers else { return }
        removeHostWindowObservers()
        installHostWindowObservers(for: hostWindow)
    }

    private func installHostWindowObservers(for window: NSWindow) {
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
    }
}
