import AppKit
public import CmuxNextDesign
public import CmuxNextSettings
public import CmuxNextWakeups

/// The window side of the Settings layer's refused-value notices (`SettingsDiagnosticPresenting`):
/// the toast goes on the key window, else the main window, through the app's toast center, and a
/// window becoming key (the app's one `NSWindow.didBecomeKeyNotification` observer on `events`)
/// retries a notice that found no window.
@MainActor public final class SettingsDiagnosticToastPresenter: SettingsDiagnosticPresenting {
    private let events: AppEvents
    private let toasts: CmuxToastCenter
    private var keyWindows: EventSubscription?

    public init(events: AppEvents, toasts: CmuxToastCenter) {
        self.events = events
        self.toasts = toasts
    }

    public func show(_ notice: SettingsDiagnosticToast, onAction: @escaping @MainActor () -> Void) -> (@MainActor () -> Void)? {
        guard let window = NSApp?.keyWindow ?? NSApp?.mainWindow else { return nil }
        let handle = toasts.show(Self.toast(notice), in: window)
        handle.onAction = { onAction() }
        return { handle.dismiss() }
    }

    /// The toast `notice` draws as: its one button, and no time-out when it has no duration.
    package static func toast(_ notice: SettingsDiagnosticToast) -> CmuxToast {
        CmuxToast(id: notice.id, message: notice.message, action: CmuxToast.Action(title: notice.actionTitle),
                  duration: notice.duration ?? CmuxToast.untilClosed)
    }

    public func followKeyWindows(_ windowBecameKey: @escaping @MainActor () -> Void) {
        // raw-observer-allow: the AppEvents subscription recipe R-notif asks for (the app's one observer); only the notice's name matches
        keyWindows = events.subscribe(NSWindow.didBecomeKeyNotification, owner: "Settings.diagnosticToasts", windowBecameKey)
    }
}
