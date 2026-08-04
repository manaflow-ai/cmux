import AppKit
import Foundation

extension SystemAppearanceObserver {
    struct Environment {
        let startEffectiveAppearanceObservation: @MainActor (@escaping @MainActor () -> Void) -> EffectiveAppearanceObservation?
        let currentAppearanceModeRawValue: @MainActor () -> String?
        let effectivePrefersDark: @MainActor () -> Bool
        let synchronizeTerminalTheme: @MainActor () -> Void
        let postSystemAppearanceDidChange: @MainActor () -> Void

        @MainActor
        static func live() -> Environment {
            Environment(
                startEffectiveAppearanceObservation: { handler in
                    guard let app = NSApp else { return nil }
                    return app.observe(\.effectiveAppearance, options: []) { _, _ in
                        Task { @MainActor in
                            handler()
                        }
                    }
                },
                currentAppearanceModeRawValue: {
                    UserDefaults.standard.string(forKey: AppearanceSettings.appearanceModeKey)
                },
                effectivePrefersDark: {
                    NSApp?.effectiveAppearance.cmuxPrefersDark == true
                },
                synchronizeTerminalTheme: {
                    GhosttyApp.shared.synchronizeThemeWithAppearance(
                        NSApp?.effectiveAppearance,
                        source: "systemAppearanceObserver"
                    )
                },
                postSystemAppearanceDidChange: {
                    NotificationCenter.default.post(name: .systemAppearanceDidChange, object: nil)
                }
            )
        }
    }
}
