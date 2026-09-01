/// Which distribution channels a What's New page (binary catalog entry or
/// remote announcement) may render on.
///
/// What's New content announces team-lane features (BETA/INTERNAL rollouts,
/// TestFlight rollback recipes), and App Review rejected the official App
/// Store app under Guideline 2.2 (submission 591a59e6) partly for such
/// beta-channel announcement surfaces. So the DEFAULT audience is the team
/// lanes only: an entry or announcement that declares no channels is shown to
/// ``MobileBuildType/dev``, ``MobileBuildType/beta``, and
/// ``MobileBuildType/internal`` builds and hidden from ``MobileBuildType/prod``
/// (the official App Store app) and ``MobileBuildType/demo``. Public channels
/// see an entry only when it EXPLICITLY lists their token, which the remote
/// catalog can do per entry (`entryChannels` / announcement `channels` in
/// `/api/whats-new`) to opt a specific page into the official app later.
///
/// Channel tokens are ``MobileBuildType/token`` values ("dev", "beta",
/// "internal", "demo", "prod"); the web catalog validates against the same
/// set. Unknown tokens never match, so a typo fails closed (hidden), and an
/// explicit empty list hides the page from every channel.
public enum MobileWhatsNewChannelPolicy {
    /// Channels shown when no channel list is declared: the team lanes.
    /// Deliberately spelled out (not derived from
    /// ``MobileBuildType/usesInternalBuildVocabulary``) so vocabulary policy
    /// and announcement audience can evolve independently.
    public static let defaultChannelTokens: Set<String> = [
        MobileBuildType.dev.token,
        MobileBuildType.beta.token,
        MobileBuildType.internal.token,
    ]

    /// Whether a page carrying `channelTokens` (`nil` = undeclared) is shown
    /// on a build of `buildType`.
    public static func isVisible(
        channelTokens: [String]?,
        buildType: MobileBuildType
    ) -> Bool {
        guard let channelTokens else {
            return defaultChannelTokens.contains(buildType.token)
        }
        return channelTokens.contains(buildType.token)
    }
}
