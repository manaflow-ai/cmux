import AppKit
import os

/// When a window's host pressure indicator samples the host (cmux#22662: a new dev
/// surface ships off). It samples only while the Debug Settings toggle
/// `hostPressure.enabled` is on and its window can be seen: in a window, not
/// minimized, and not fully occluded (hidden app, another Space, covered).
/// Everything else (toggle off, hidden, minimized, occluded, closed) means no
/// subscription, so no service, no monitor, no 15 s timer and no reads.
@MainActor struct HostPressureSampling: Equatable {
    var enabled: Bool
    var windowVisible: Bool

    var samples: Bool { enabled && windowVisible }

    /// Whether `window` can be seen right now (the app not hidden either).
    static func isVisible(_ window: NSWindow?) -> Bool {
        guard let window, !NSApplication.shared.isHidden else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    /// The window notifications after which `isVisible` may differ (ordering a window out or in
    /// changes its occlusion state).
    static let windowChanges: [Notification.Name] = [
        NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
        NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification,
    ]

    /// The app notifications after which `isVisible` may differ (Hide cmux, then show it again).
    static let appChanges: [Notification.Name] = [NSApplication.didHideNotification, NSApplication.didUnhideNotification]
}

/// One window's subscription to the app's `HostPressureService`. `cancel()` ends it at once;
/// a subscription released without one (its indicator freed off the main thread, where the
/// indicator's deinit cannot touch main-actor state) ends on the main actor instead, so a
/// window never leaves a subscriber behind that would keep the monitor's timer running.
nonisolated final class HostPressureSubscription: Sendable {
    let service: HostPressureService
    private let live = OSAllocatedUnfairLock(initialState: true)

    @MainActor init(_ service: HostPressureService) {
        self.service = service
        service.subscribe()
    }

    /// Whether this call ended it (the first `cancel()` or the deinit).
    private func end() -> Bool {
        live.withLock { live in
            defer { live = false }
            return live
        }
    }

    @MainActor func cancel() {
        if end() { service.unsubscribe() }
    }

    deinit {
        guard end() else { return }
        let service = service
        // task-owner: one hop that ends a subscription released without cancel(); it ends after the call
        Task { @MainActor in service.unsubscribe() }
    }
}

/// Tasks cancelled together from any thread (a view's nonisolated deinit included).
nonisolated final class HostPressureTasks: Sendable {
    private let tasks = OSAllocatedUnfairLock<[Task<Void, Never>]>(initialState: [])

    func add(_ task: Task<Void, Never>) {
        tasks.withLock { $0.append(task) }
    }

    func cancelAll() {
        let all = tasks.withLock { tasks in
            defer { tasks = [] }
            return tasks
        }
        all.forEach { $0.cancel() }
    }

    deinit { cancelAll() }
}
