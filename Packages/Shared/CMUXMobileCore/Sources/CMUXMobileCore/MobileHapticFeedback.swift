import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// App-wide policy and emission entry points for cmux-owned mobile haptics.
///
/// The preference defaults to enabled without writing to `UserDefaults`, which
/// preserves existing behavior for current installs. Every cmux haptic must go
/// through this type so the Settings toggle applies across package boundaries.
public struct MobileHapticFeedback {
    public static let enabledDefaultsKey = "cmux.mobile.hapticFeedbackEnabled"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var isEnabled: Bool {
        defaults.object(forKey: Self.enabledDefaultsKey) as? Bool ?? true
    }

    public func setEnabled(_ isEnabled: Bool) {
        defaults.set(isEnabled, forKey: Self.enabledDefaultsKey)
    }

    public func performIfEnabled(_ feedback: () -> Void) {
        guard isEnabled else { return }
        feedback()
    }

    #if canImport(UIKit)
    @MainActor
    public func prepare(_ generator: UIFeedbackGenerator) {
        performIfEnabled {
            generator.prepare()
        }
    }

    @MainActor
    public func impact(_ generator: UIImpactFeedbackGenerator) {
        performIfEnabled {
            generator.impactOccurred()
        }
    }

    @MainActor
    public func impact(style: UIImpactFeedbackGenerator.FeedbackStyle) {
        performIfEnabled {
            UIImpactFeedbackGenerator(style: style).impactOccurred()
        }
    }

    @MainActor
    public func notification(
        _ feedbackType: UINotificationFeedbackGenerator.FeedbackType
    ) {
        performIfEnabled {
            UINotificationFeedbackGenerator().notificationOccurred(feedbackType)
        }
    }
    #endif
}
