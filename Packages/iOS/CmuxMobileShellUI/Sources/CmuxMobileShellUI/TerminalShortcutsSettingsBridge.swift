#if os(iOS)
import SwiftUI

/// Temporary compatibility bridge for the remaining SwiftUI-owned screens.
/// Native presentation paths use ``TerminalShortcutsSettingsViewController``
/// directly; this file disappears with the owning screen migrations.
struct TerminalShortcutsSettingsView: UIViewControllerRepresentable {
    private let scope: TerminalShortcutsSettingsScope

    init(scope: TerminalShortcutsSettingsScope = .terminal) {
        self.scope = scope
    }

    func makeUIViewController(context: Context) -> UINavigationController {
        UINavigationController(
            rootViewController: TerminalShortcutsSettingsViewController(scope: scope)
        )
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}
}
#endif
