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
    /// UserDefaults key for the app-wide haptic preference.
    public static let enabledDefaultsKey = "cmux.mobile.hapticFeedbackEnabled"

    private let defaults: UserDefaults

    /// Creates a haptic reader backed by the supplied defaults store.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether app-owned haptic feedback is currently enabled.
    public var isEnabled: Bool {
        defaults.object(forKey: Self.enabledDefaultsKey) as? Bool ?? true
    }

    /// Runs `feedback` only when app-owned haptics are enabled.
    public func performIfEnabled(_ feedback: () -> Void) {
        guard isEnabled else { return }
        feedback()
    }

    #if canImport(UIKit)
    /// Prepares a UIKit feedback generator only when haptics are enabled.
    @MainActor
    public func prepare(_ generator: UIFeedbackGenerator) {
        performIfEnabled {
            generator.prepare()
        }
    }

    /// Emits impact feedback through an existing generator when enabled.
    @MainActor
    public func impact(_ generator: UIImpactFeedbackGenerator) {
        performIfEnabled {
            generator.impactOccurred()
        }
    }

    /// Emits one impact using a temporary generator when enabled.
    @MainActor
    public func impact(style: UIImpactFeedbackGenerator.FeedbackStyle) {
        performIfEnabled {
            UIImpactFeedbackGenerator(style: style).impactOccurred()
        }
    }

    /// Emits notification feedback when enabled.
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
