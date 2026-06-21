import Foundation
import CmuxSettings

enum PanelTitleUpdateCoalescingSettings {
    private static let terminalSettings = SettingCatalog().terminal
    static let defaultDelay: TimeInterval = 1.0 / 30.0
    static let minimumDelayMilliseconds = 33
    static let maximumDelayMilliseconds = 5_000

    static func isEnabled(settings: any SettingsReading) -> Bool {
        settings.value(for: terminalSettings.titleUpdateCoalescingEnabled)
    }

    static func diagnosticsEnabled(settings: any SettingsReading) -> Bool {
        settings.value(for: terminalSettings.titleUpdateDiagnostics)
    }

    static func delay(settings: any SettingsReading) -> TimeInterval {
        guard isEnabled(settings: settings) else { return defaultDelay }
        let rawMilliseconds = settings.value(for: terminalSettings.titleUpdateCoalescingMilliseconds)
        let clampedMilliseconds = min(max(rawMilliseconds, minimumDelayMilliseconds), maximumDelayMilliseconds)
        return TimeInterval(clampedMilliseconds) / 1_000.0
    }

    static func configuredDelayMilliseconds(settings: any SettingsReading) -> Int {
        Int((delay(settings: settings) * 1_000).rounded())
    }
}

/// Coalesces repeated main-thread signals into one callback after a short delay.
/// Useful for notification storms where only the latest update matters.
final class NotificationBurstCoalescer {
    private var delay: TimeInterval
    private var isFlushScheduled = false
    private var pendingAction: (() -> Void)?

    init(delay: TimeInterval = 1.0 / 30.0) {
        self.delay = max(0, delay)
    }

    func signal(delay newDelay: TimeInterval? = nil, _ action: @escaping () -> Void) {
        precondition(Thread.isMainThread, "NotificationBurstCoalescer must be used on the main thread")
        if let newDelay {
            delay = max(0, newDelay)
        }
        pendingAction = action
        scheduleFlushIfNeeded()
    }

    private func scheduleFlushIfNeeded() {
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.flush()
        }
    }

    private func flush() {
        precondition(Thread.isMainThread, "NotificationBurstCoalescer must be used on the main thread")
        isFlushScheduled = false
        guard let action = pendingAction else { return }
        pendingAction = nil
        action()
        if pendingAction != nil {
            scheduleFlushIfNeeded()
        }
    }
}
