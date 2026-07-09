import Foundation
import CmuxSettings
import CmuxWorkspaces

nonisolated enum PanelTitleUpdateCoalescingSettings {
    private nonisolated static let terminalSettings = SettingCatalog().terminal
    nonisolated static let defaultDelay: TimeInterval = 1.0 / 30.0
    nonisolated static let minimumDelayMilliseconds = 33
    nonisolated static let maximumDelayMilliseconds = 5_000

    nonisolated static func isEnabled(settings: any SettingsReading) -> Bool {
        settings.value(for: terminalSettings.titleUpdateCoalescingEnabled)
    }

    nonisolated static func diagnosticsEnabled(settings: any SettingsReading) -> Bool {
        settings.value(for: terminalSettings.titleUpdateDiagnostics)
    }

    nonisolated static func delay(settings: any SettingsReading) -> TimeInterval {
        guard isEnabled(settings: settings) else { return defaultDelay }
        let rawMilliseconds = settings.value(for: terminalSettings.titleUpdateCoalescingMilliseconds)
        let clampedMilliseconds = min(max(rawMilliseconds, minimumDelayMilliseconds), maximumDelayMilliseconds)
        return TimeInterval(clampedMilliseconds) / 1_000.0
    }

    nonisolated static func configuredDelayMilliseconds(settings: any SettingsReading) -> Int {
        Int((delay(settings: settings) * 1_000).rounded())
    }
}

@MainActor
final class PanelTitleUpdateCoalescer: TitleFlushDelayScheduling {
    typealias Cancellation = @MainActor () -> Void

    private var pendingCancellation: Cancellation?
    private var pendingAction: (() -> Void)?
    private let defaultDelay: TimeInterval
    private let schedule: (_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Cancellation

    init(
        delay: TimeInterval = PanelTitleUpdateCoalescingSettings.defaultDelay,
        schedule: @escaping (_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Cancellation = { delay, action in
            let workItem = DispatchWorkItem {
                MainActor.assumeIsolated {
                    action()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: workItem)
            return {
                workItem.cancel()
            }
        }
    ) {
        self.defaultDelay = max(0, delay)
        self.schedule = schedule
    }

    func signal(_ action: @escaping () -> Void) {
        signal(delay: defaultDelay, action)
    }

    func signal(delay: TimeInterval, _ action: @escaping () -> Void) {
        precondition(Thread.isMainThread, "PanelTitleUpdateCoalescer must be used on the main thread")
        pendingAction = action
        pendingCancellation?()
        pendingCancellation = schedule(max(0, delay)) { [weak self] in
            self?.flush()
        }
    }

    private func flush() {
        precondition(Thread.isMainThread, "PanelTitleUpdateCoalescer must be used on the main thread")
        pendingCancellation = nil
        guard let action = pendingAction else { return }
        pendingAction = nil
        action()
    }
}
