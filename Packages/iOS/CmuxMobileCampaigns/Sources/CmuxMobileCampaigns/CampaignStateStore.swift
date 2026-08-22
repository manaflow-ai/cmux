public import Foundation

/// One campaign's local presentation history.
public struct CampaignPresentationState: Sendable, Equatable {
    /// Marketing versions this campaign was presented under.
    public var presentedVersions: [String]
    /// Whether the user explicitly dismissed it (button, close, or swipe).
    public var isDismissed: Bool

    public init(presentedVersions: [String] = [], isDismissed: Bool = false) {
        self.presentedVersions = presentedVersions
        self.isDismissed = isDismissed
    }
}

/// Per-campaign presented/dismissed history in injected user defaults,
/// following the dismissal-store pattern used by the Mac update hint. Keys are
/// campaign-id scoped, so retiring a campaign leaves inert entries behind and
/// ids must never be reused for different content.
public struct CampaignStateStore {
    private static let presentedKeyPrefix = "dev.cmux.mobile.campaigns.presented."
    private static let dismissedKeyPrefix = "dev.cmux.mobile.campaigns.dismissed."

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func state(for campaignID: String) -> CampaignPresentationState {
        CampaignPresentationState(
            presentedVersions: defaults.stringArray(
                forKey: Self.presentedKeyPrefix + campaignID
            ) ?? [],
            isDismissed: defaults.bool(forKey: Self.dismissedKeyPrefix + campaignID)
        )
    }

    public func recordPresented(campaignID: String, appVersion: String) {
        let key = Self.presentedKeyPrefix + campaignID
        var versions = defaults.stringArray(forKey: key) ?? []
        guard !versions.contains(appVersion) else { return }
        versions.append(appVersion)
        defaults.set(versions, forKey: key)
    }

    public func recordDismissed(campaignID: String) {
        defaults.set(true, forKey: Self.dismissedKeyPrefix + campaignID)
    }
}
