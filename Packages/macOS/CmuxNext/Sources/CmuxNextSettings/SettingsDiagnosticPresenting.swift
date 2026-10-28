public import CmuxNextDesign

/// Where ``SettingsController/start(announcingDiagnostics:)`` shows a refused cmux-next.json value:
/// the App passes CmuxNextSettingsWindow's `SettingsDiagnosticToastPresenter`, which puts the toast on
/// the key window. Settings decides what to say and when; the presenter owns the windows.
@MainActor public protocol SettingsDiagnosticPresenting: AnyObject {
    /// Shows `toast` on the key (or main) window and calls `onAction` when its button is pressed.
    /// Returns what closes it, or nil when no window is open (the notice then waits for one).
    func show(_ toast: CmuxToast, onAction: @escaping @MainActor () -> Void) -> (@MainActor () -> Void)?

    /// Calls `windowBecameKey` each time a window becomes key, for as long as the presenter lives.
    func followKeyWindows(_ windowBecameKey: @escaping @MainActor () -> Void)
}
