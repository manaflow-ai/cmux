import CmuxSettings
import Foundation

/// UI-facing labels for ``UpdateChannel``, shown by the App section's update channel picker.
extension UpdateChannel {
    /// Short label shown in the channel picker.
    var displayName: String {
        switch self {
        case .stable:
            return String(localized: "settings.updates.channel.stable", defaultValue: "Stable")
        case .rc:
            return String(localized: "settings.updates.channel.rc", defaultValue: "Release candidate")
        }
    }
}
