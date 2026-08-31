import AppKit
import Foundation

extension SystemAppearanceObserver {
    struct Environment {
        let startEffectiveAppearanceObservation: @MainActor (@escaping @MainActor () -> Void) -> EffectiveAppearanceObservation?
        let startSystemColorsObservation: @MainActor (@escaping @MainActor () -> Void) -> SystemColorsObservation?
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
                startSystemColorsObservation: { handler in
                    let token = NotificationCenter.default.addObserver(
                        forName: NSColor.systemColorsDidChangeNotification,
                        object: nil,
                        queue: .main
                    ) { _ in
                        // NotificationCenter delivers this observer on the
                        // main queue above, so invoke the main-actor seam
                        // directly instead of creating one task per event.
                        MainActor.assumeIsolated {
                            handler()
                        }
                    }
                    return NotificationCenterSystemColorsObservation(token: token)
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
