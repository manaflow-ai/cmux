import Foundation

/// Selects the product surface exposed by the mobile client.
public enum MobileExperienceProfile: String, Equatable, Sendable {
    /// The complete development and dogfood experience.
    case full
    /// The focused first-release experience centered on remote agent control.
    case mvp

    /// Creates a profile from an Info.plist or build-setting value.
    ///
    /// Unknown and missing values resolve to ``full`` so local development
    /// never loses tools because of a malformed optional setting.
    public init(configurationValue: String?) {
        let normalized = configurationValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self = normalized == Self.mvp.rawValue ? .mvp : .full
    }
}
