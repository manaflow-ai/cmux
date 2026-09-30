import AppKit
import CmuxSettings
import Foundation

/// App-scoped owner for the voice-dictation coordinator.
///
/// The SwiftUI composition root retains this runtime for the application
/// lifetime. The AppKit delegate receives only injected shortcut and toggle
/// closures, keeping feature state out of the process-wide delegate singleton.
@MainActor
final class VoiceDictationRuntime {
    private let coordinator: VoiceDictationCoordinator

    init(
        catalog: SettingCatalog,
        defaults: UserDefaults = .standard,
        focusedTerminalTarget: @escaping @MainActor () -> VoiceDictationTerminalTarget? = {
            AppDelegate.shared?.voiceDictationFocusedTerminalTarget()
        }
    ) {
        coordinator = VoiceDictationCoordinator(
            catalog: catalog,
            defaults: defaults,
            focusedTerminalTarget: focusedTerminalTarget
        )
    }

    /// Handles a key-down of the Toggle Voice Dictation shortcut.
    @discardableResult
    func handleShortcut(_ event: NSEvent) -> Bool {
        coordinator.handleShortcut(event)
    }

    /// Handles the mic button and the command palette entry.
    @discardableResult
    func toggleFromUI() -> Bool {
        coordinator.toggleFromUI()
    }

    /// Handles a tab-bar action with its pane target resolved synchronously.
    @discardableResult
    func toggleFromUI(target: VoiceDictationTerminalTarget) -> Bool {
        coordinator.toggleFromUI(target: target)
    }
}
