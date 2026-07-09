import AppKit
import Foundation

extension SystemAppearanceObserver {
    struct Environment {
        let startEffectiveAppearanceObservation: (@escaping @MainActor () -> Void) -> EffectiveAppearanceObservation?
        let currentAppearanceModeRawValue: () -> String?
        let effectivePrefersDark: () -> Bool
        let postSystemAppearanceDidChange: () -> Void

        static func live() -> Environment {
            Environment(
                startEffectiveAppearanceObservation: { handler in
                    // `Environment` is nested in the `@MainActor` `SystemAppearanceObserver`,
                    // which makes the compiler check this closure's body for actor-isolation
                    // crossings even though `startEffectiveAppearanceObservation`'s declared type
                    // stays plain/non-isolated. `startObserving()` (the only caller) is
                    // main-actor-isolated, so this always runs on the main actor in practice;
                    // `assumeIsolated` makes that explicit for the type checker.
                    MainActor.assumeIsolated {
                        guard let app = NSApp else { return nil }
                        return app.observe(\.effectiveAppearance, options: []) { _, _ in
                            Task { @MainActor in
                                handler()
                            }
                        }
                    }
                },
                currentAppearanceModeRawValue: {
                    UserDefaults.standard.string(forKey: AppearanceSettings.appearanceModeKey)
                },
                effectivePrefersDark: {
                    MainActor.assumeIsolated {
                        NSApp?.effectiveAppearance.cmuxPrefersDark == true
                    }
                },
                postSystemAppearanceDidChange: {
                    NotificationCenter.default.post(name: .systemAppearanceDidChange, object: nil)
                }
            )
        }
    }
}
