import CmuxSettings
import SwiftUI

/// View modifier that presents the most recent ``SettingsErrorLog``
/// entry as a standard macOS alert.
///
/// Matches the behavior cmux's existing settings UI uses for write
/// failures — a modal alert with OK to dismiss, *not* an inline banner.
/// The modifier is `internal`; views attach it via
/// ``SwiftUI/View/settingsErrorAlert(log:)``.
struct SettingsErrorAlertModifier: ViewModifier {
    @Bindable var log: SettingsErrorLog

    func body(content: Content) -> some View {
        content
            .alert(
                Text(String(localized: "settings.error.alert.title", defaultValue: "Couldn't save setting")),
                isPresented: Binding(
                    get: { log.entries.last != nil },
                    set: { newValue in
                        if !newValue, let last = log.entries.last {
                            log.dismiss(last.id)
                        }
                    }
                ),
                presenting: log.entries.last
            ) { _ in
                Button(String(localized: "settings.error.alert.dismiss", defaultValue: "OK")) {
                    if let last = log.entries.last {
                        log.dismiss(last.id)
                    }
                }
            } message: { entry in
                Text("\(entry.keyID): \(entry.message)")
            }
    }
}

extension View {
    /// Attaches the standard settings error alert. The most recent
    /// unacknowledged entry in ``log`` surfaces as a modal alert.
    public func settingsErrorAlert(log: SettingsErrorLog) -> some View {
        modifier(SettingsErrorAlertModifier(log: log))
    }
}
