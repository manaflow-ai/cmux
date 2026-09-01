import CmuxSettings
import Foundation

/// App-scoped owner for the voice-dictation coordinator.
///
/// The SwiftUI composition root retains this runtime for the application
/// lifetime. The AppKit delegate receives only an injected shortcut closure,
/// keeping feature state out of the process-wide delegate singleton.
@MainActor
final class VoiceDictationRuntime {
    private let coordinator: VoiceDictationCoordinator

    init(
        catalog: SettingCatalog,
        defaults: UserDefaults = .standard,
        focusedTerminalPanel: @escaping () -> TerminalPanel?
    ) {
        coordinator = VoiceDictationCoordinator(
            catalog: catalog,
            defaults: defaults,
            focusedTerminalPanel: focusedTerminalPanel
        )
    }

    @discardableResult
    func handleShortcutToggle() -> Bool {
        coordinator.handleShortcutToggle()
    }
}
