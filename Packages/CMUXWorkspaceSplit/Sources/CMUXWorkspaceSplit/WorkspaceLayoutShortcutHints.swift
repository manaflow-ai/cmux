import AppKit
import SwiftUI

@MainActor
struct WorkspaceLayoutMountedTabEntry {
    let contentId: UUID
    let content: WorkspacePaneContent
    let mountIdentity: WorkspacePaneMountIdentity
}

struct WorkspaceLayoutPaneTabShortcutHintModifier: Equatable {
    let modifierFlags: NSEvent.ModifierFlags
    let symbol: String
}

enum WorkspaceLayoutPaneTabShortcutHintPolicy {
    static let intentionalHoldDelay: TimeInterval = 0.30

    static func hintModifier(
        for modifierFlags: NSEvent.ModifierFlags,
        defaults: UserDefaults = .standard
    ) -> WorkspaceLayoutPaneTabShortcutHintModifier? {
        guard WorkspaceLayoutShortcutHintSettings.showHintsOnCommandHoldEnabled(defaults: defaults) else {
            return nil
        }
        let shortcut = WorkspaceLayoutShortcutHintSettings.selectSurfaceByNumberShortcutProvider()
        guard !shortcut.hasChord else { return nil }
        let normalized = modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        guard normalized == shortcut.modifierFlags || normalized == [.command] else { return nil }
        return WorkspaceLayoutPaneTabShortcutHintModifier(
            modifierFlags: shortcut.modifierFlags,
            symbol: shortcut.modifierDisplayString
        )
    }

    static func isCurrentWindow(
        hostWindowNumber: Int?,
        hostWindowIsKey: Bool,
        eventWindowNumber: Int?,
        keyWindowNumber: Int?
    ) -> Bool {
        guard let hostWindowNumber, hostWindowIsKey else { return false }
        if let eventWindowNumber {
            return eventWindowNumber == hostWindowNumber
        }
        return keyWindowNumber == hostWindowNumber
    }

    static func shouldShowHints(
        for modifierFlags: NSEvent.ModifierFlags,
        hostWindowNumber: Int?,
        hostWindowIsKey: Bool,
        eventWindowNumber: Int?,
        keyWindowNumber: Int?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        hintModifier(for: modifierFlags, defaults: defaults) != nil &&
            isCurrentWindow(
                hostWindowNumber: hostWindowNumber,
                hostWindowIsKey: hostWindowIsKey,
                eventWindowNumber: eventWindowNumber,
                keyWindowNumber: keyWindowNumber
            )
    }
}

func workspaceLayoutTabControlShortcutDigit(for index: Int, tabCount: Int) -> Int? {
    for digit in 1...9 {
        if workspaceLayoutTabIndexForControlShortcutDigit(digit, tabCount: tabCount) == index {
            return digit
        }
    }
    return nil
}

func workspaceLayoutTabIndexForControlShortcutDigit(_ digit: Int, tabCount: Int) -> Int? {
    guard tabCount > 0, digit >= 1, digit <= 9 else { return nil }
    if digit == 9 {
        return tabCount - 1
    }
    let index = digit - 1
    return index < tabCount ? index : nil
}

@MainActor
final class WorkspaceLayoutPaneTabShortcutHintMonitor {
    private(set) var isShortcutHintVisible = false {
        didSet {
            guard isShortcutHintVisible != oldValue else { return }
            onChange?()
        }
    }

    private(set) var shortcutModifierSymbol = "⌃" {
        didSet {
            guard shortcutModifierSymbol != oldValue else { return }
            onChange?()
        }
    }

    var onChange: (() -> Void)?

    weak var hostWindow: NSWindow?
    var hostWindowDidBecomeKeyObserver: NSObjectProtocol?
    var hostWindowDidResignKeyObserver: NSObjectProtocol?
    var flagsMonitor: Any?
    var keyDownMonitor: Any?
    var resignObserver: NSObjectProtocol?
    var pendingShowWorkItem: DispatchWorkItem?
    var pendingModifier: WorkspaceLayoutPaneTabShortcutHintModifier?

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
            guard self?.isCurrentWindow(eventWindow: event.window) == true else { return event }
            self?.cancelPendingHintShow(resetVisible: true)
            return event
        }

        resignObserver = NotificationCenter.default.addObserver(
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
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        removeHostWindowObservers()
        cancelPendingHintShow(resetVisible: true)
    }

    func isCurrentWindow(eventWindow: NSWindow?) -> Bool {
        WorkspaceLayoutPaneTabShortcutHintPolicy.isCurrentWindow(
            hostWindowNumber: hostWindow?.windowNumber,
            hostWindowIsKey: hostWindow?.isKeyWindow ?? false,
            eventWindowNumber: eventWindow?.windowNumber,
            keyWindowNumber: NSApp.keyWindow?.windowNumber
        )
    }

    func update(from modifierFlags: NSEvent.ModifierFlags, eventWindow: NSWindow?) {
        guard WorkspaceLayoutPaneTabShortcutHintPolicy.shouldShowHints(
            for: modifierFlags,
            hostWindowNumber: hostWindow?.windowNumber,
            hostWindowIsKey: hostWindow?.isKeyWindow ?? false,
            eventWindowNumber: eventWindow?.windowNumber,
            keyWindowNumber: NSApp.keyWindow?.windowNumber
        ) else {
            cancelPendingHintShow(resetVisible: true)
            return
        }

        guard let modifier = WorkspaceLayoutPaneTabShortcutHintPolicy.hintModifier(for: modifierFlags) else {
            cancelPendingHintShow(resetVisible: true)
            return
        }

        if isShortcutHintVisible {
            shortcutModifierSymbol = modifier.symbol
            return
        }

        queueHintShow(for: modifier)
    }

    func queueHintShow(for modifier: WorkspaceLayoutPaneTabShortcutHintModifier) {
        if pendingModifier == modifier, pendingShowWorkItem != nil {
            return
        }

        pendingShowWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingShowWorkItem = nil
            self.pendingModifier = nil
            guard WorkspaceLayoutPaneTabShortcutHintPolicy.shouldShowHints(
                for: NSEvent.modifierFlags,
                hostWindowNumber: self.hostWindow?.windowNumber,
                hostWindowIsKey: self.hostWindow?.isKeyWindow ?? false,
                eventWindowNumber: nil,
                keyWindowNumber: NSApp.keyWindow?.windowNumber
            ) else {
                return
            }
            guard let currentModifier = WorkspaceLayoutPaneTabShortcutHintPolicy.hintModifier(for: NSEvent.modifierFlags) else {
                return
            }
            self.shortcutModifierSymbol = currentModifier.symbol
            self.isShortcutHintVisible = true
        }

        pendingModifier = modifier
        pendingShowWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + WorkspaceLayoutPaneTabShortcutHintPolicy.intentionalHoldDelay,
            execute: workItem
        )
    }

    func cancelPendingHintShow(resetVisible: Bool) {
        pendingShowWorkItem?.cancel()
        pendingShowWorkItem = nil
        pendingModifier = nil
        if resetVisible {
            isShortcutHintVisible = false
        }
    }

    func removeHostWindowObservers() {
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
