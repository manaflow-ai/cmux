import AppKit
import CmuxSettings
import Foundation
import os

/// App-target ``BindableCommandCatalogProviding`` that resolves the focused
/// terminal window's bindable commands via a one-shot, window-targeted
/// NotificationCenter round-trip (the same pattern the command palette uses to
/// reach a `ContentView`, since no global `ContentView` registry exists).
@MainActor
final class HostBindableCommandCatalog: BindableCommandCatalogProviding {
    init() {}

    func bindableCommands() async -> [BindableCommandDescriptor] {
        // Target the active main terminal window, never the key window: the
        // picker is opened from the Settings panel, so `NSApp.keyWindow` is the
        // Settings window and no terminal `ContentView` would answer the request.
        guard let targetWindow = AppDelegate.shared?.activeMainTerminalWindow()
            ?? NSApp.mainWindow else { return [] }
        let replyId = UUID().uuidString
        return await withCheckedContinuation { continuation in
            // Resume exactly once: on reply, or on a short deadline if no window
            // responds. `OSAllocatedUnfairLock` guards the one-shot flag — a
            // synchronous compare-and-set across the observer and the timeout.
            let guardState = OneShotResumeGuard()
            var observer: NSObjectProtocol?
            observer = NotificationCenter.default.addObserver(
                forName: BoundCommandNotifications.catalogReply,
                object: nil,
                queue: .main
            ) { note in
                guard note.userInfo?[BoundCommandNotifications.replyIdKey] as? String == replyId else { return }
                let descriptors = note.userInfo?[BoundCommandNotifications.descriptorsKey] as? [BindableCommandDescriptor] ?? []
                if guardState.claim() {
                    if let observer { NotificationCenter.default.removeObserver(observer) }
                    continuation.resume(returning: descriptors)
                }
            }
            NotificationCenter.default.post(
                name: BoundCommandNotifications.catalogRequest,
                object: targetWindow,
                userInfo: [BoundCommandNotifications.replyIdKey: replyId]
            )
            // Deadline so the picker never hangs if the window can't respond.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300)) // bounded deadline; picker fallback
                if guardState.claim() {
                    if let observer { NotificationCenter.default.removeObserver(observer) }
                    continuation.resume(returning: [])
                }
            }
        }
    }
}

/// One-shot resume guard: a synchronous compare-and-set over a `Bool`, so the
/// reply observer and the timeout race to resume the continuation exactly once.
private final class OneShotResumeGuard: @unchecked Sendable {
    // OSAllocatedUnfairLock guarding a one-shot flag (lock carve-out): the
    // critical section is a single Bool compare-and-set from non-async callbacks.
    private let lock = OSAllocatedUnfairLock(initialState: false)
    func claim() -> Bool {
        lock.withLock { claimed in
            if claimed { return false }
            claimed = true
            return true
        }
    }
}
