#if canImport(UIKit)
import UIKit

/// Package-local gate for conversation UI feedback.
enum ConversationHaptics {
    private static let settingKey = "cmuxMobile.settings.hapticsEnabled"

    private static var isEnabled: Bool {
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { return false }
        return UserDefaults.standard.object(forKey: settingKey) as? Bool ?? false
    }

    @MainActor static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle, intensity: CGFloat = 1) {
        guard isEnabled else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred(intensity: intensity)
    }

    @MainActor static func selectionChanged() {
        guard isEnabled else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    @MainActor static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        guard isEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }
}
#endif
