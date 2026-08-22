public import Foundation

/// The device-side facts campaigns are targeted against.
public struct CampaignEligibilityContext: Sendable {
    /// The platform string matched against `Campaign.platforms`.
    public var platform: String
    /// The running app's marketing version; `nil` skips version bounds.
    public var appVersion: CampaignAppVersion?
    /// The stable per-install key hashed for percentage rollouts.
    public var rolloutKey: String
    public var now: Date

    public init(
        platform: String = "ios",
        appVersion: CampaignAppVersion?,
        rolloutKey: String,
        now: Date
    ) {
        self.platform = platform
        self.appVersion = appVersion
        self.rolloutKey = rolloutKey
        self.now = now
    }
}

public enum CampaignEligibility {
    /// Whether a campaign targets this install right now, ignoring
    /// presented/dismissed state (used for both live surfaces and What's New).
    public static func isTargeted(_ campaign: Campaign, context: CampaignEligibilityContext) -> Bool {
        guard campaign.platforms.contains(context.platform) else { return false }
        if campaign.minAppVersion != nil || campaign.maxAppVersion != nil {
            // Version-bounded campaigns fail closed on an unparseable app
            // version rather than showing on a build they never targeted.
            guard let appVersion = context.appVersion else { return false }
            if let minVersion = campaign.minAppVersion, appVersion < minVersion { return false }
            if let maxVersion = campaign.maxAppVersion, maxVersion < appVersion { return false }
        }
        if let startsAt = campaign.startsAt, context.now < startsAt { return false }
        if let endsAt = campaign.endsAt, endsAt <= context.now { return false }
        guard campaign.rolloutPercent >= 100
            || rolloutBucket(campaignID: campaign.id, rolloutKey: context.rolloutKey)
                < campaign.rolloutPercent else { return false }
        return true
    }

    /// Whether presented/dismissed history still allows another presentation.
    public static func passesReshowPolicy(
        _ campaign: Campaign,
        state: CampaignPresentationState,
        appVersion: CampaignAppVersion?
    ) -> Bool {
        // An explicit dismissal always wins, whatever the policy.
        guard !state.isDismissed else { return false }
        switch campaign.reshowPolicy {
        case .once:
            return state.presentedVersions.isEmpty
        case .oncePerVersion:
            guard let appVersion else { return state.presentedVersions.isEmpty }
            return !state.presentedVersions.contains(appVersion.description)
        case .untilDismissed:
            return true
        }
    }

    /// The deterministic rollout bucket in [0, 100): FNV-1a over
    /// "campaignID:rolloutKey", so one install sees a stable decision per
    /// campaign and different campaigns slice the population independently.
    public static func rolloutBucket(campaignID: String, rolloutKey: String) -> Double {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in Array("\(campaignID):\(rolloutKey)".utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Double(hash % 10_000) / 100
    }

    /// Highest priority first; ties break on id for a stable order.
    public static func sortedByPriority(_ campaigns: [Campaign]) -> [Campaign] {
        campaigns.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            return lhs.id < rhs.id
        }
    }
}
