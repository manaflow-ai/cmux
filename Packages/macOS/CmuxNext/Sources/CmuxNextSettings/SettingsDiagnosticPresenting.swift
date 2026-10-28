/// Where ``SettingsController/start(announcingDiagnostics:)`` shows a refused cmux-next.json value:
/// the App passes CmuxNextSettingsWindow's `SettingsDiagnosticToastPresenter`, which puts the toast on
/// the key window. Settings decides what to say and when; the presenter owns the windows and the
/// toast's look.
@MainActor public protocol SettingsDiagnosticPresenting: AnyObject {
    /// Shows `notice` on the key (or main) window and calls `onAction` when its button is pressed.
    /// Returns what closes it, or nil when no window is open (the notice then waits for one).
    func show(_ notice: SettingsDiagnosticToast, onAction: @escaping @MainActor () -> Void) -> (@MainActor () -> Void)?

    /// Calls `windowBecameKey` each time a window becomes key, for as long as the presenter lives.
    func followKeyWindows(_ windowBecameKey: @escaping @MainActor () -> Void)
}

/// One refused-value notice as the presenter shows it: a toast on the key window with one button.
public nonisolated struct SettingsDiagnosticToast: Equatable, Sendable {
    /// A newer notice with the same id replaces the one showing.
    public var id: String
    public var message: String
    /// The button's title (Show in Settings, Open File).
    public var actionTitle: String
    /// How long it shows; nil keeps it until its button or close button (Debug Settings
    /// `settings.diagnosticToast` keeps it up until closed).
    public var duration: Duration?

    public init(id: String, message: String, actionTitle: String, duration: Duration?) {
        self.id = id
        self.message = message
        self.actionTitle = actionTitle
        self.duration = duration
    }
}
