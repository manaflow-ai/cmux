import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

/// Tests the remote-configurable minimum-Mac-version policy: the version
/// stamp grammar (released and nightly), tier selection by the running iOS
/// version, channel resolution from the authenticated instance tag, the
/// per-channel violation rules, and decoding of the
/// `/api/mobile-mac-compat` payload. All pure functions, so the whole
/// "reported Mac version -> admit or explain the required update" contract
/// verifies without a live connection.
@Suite struct MobileMacCompatPolicyTests {
    private func version(_ string: String) -> MobileMacAppVersion {
        MobileMacAppVersion(parsing: string)!
    }

    /// One tier at iOS 1.0.4: stable >= 0.64.23, nightly >= 0.64.22-nightly.100.
    private var policy: MobileMacCompatPolicy {
        MobileMacCompatPolicy(tiers: [
            MobileMacCompatPolicy.Tier(
                minIOSVersion: version("1.0.4"),
                stableMinVersion: version("0.64.23"),
                nightly: MobileMacCompatPolicy.NightlyRequirement(
                    minBaseVersion: version("0.64.22"),
                    minBuild: 100
                )
            ),
        ])
    }

    // MARK: - Version stamp grammar

    @Test func stampParsesReleasedVersion() {
        let stamp = MobileMacBuildVersionStamp(parsing: "0.64.22")
        #expect(stamp?.base == version("0.64.22"))
        #expect(stamp?.nightlyBuild == nil)
    }

    @Test func stampParsesNightlyVersion() {
        let stamp = MobileMacBuildVersionStamp(parsing: "0.64.22-nightly.3345650013201")
        #expect(stamp?.base == version("0.64.22"))
        #expect(stamp?.nightlyBuild == 3_345_650_013_201)
    }

    @Test func stampTrimsWhitespace() {
        #expect(MobileMacBuildVersionStamp(parsing: " 0.64.22 ")?.base == version("0.64.22"))
    }

    @Test(arguments: [
        "", "dev", "0.64.22-nightly.", "0.64.22-nightly.12a", "0.64.22-beta.1", "-nightly.5",
    ])
    func stampRejectsMalformedVersions(_ raw: String) {
        #expect(MobileMacBuildVersionStamp(parsing: raw) == nil)
    }

    // MARK: - Tier selection

    @Test func tierSelectionUsesGreatestMinimumAtOrBelowAppVersion() {
        let tiered = MobileMacCompatPolicy(tiers: [
            MobileMacCompatPolicy.Tier(
                minIOSVersion: version("1.0.4"),
                stableMinVersion: version("0.64.23"),
                nightly: nil
            ),
            MobileMacCompatPolicy.Tier(
                minIOSVersion: version("1.1"),
                stableMinVersion: version("0.65.0"),
                nightly: nil
            ),
        ])
        #expect(tiered.tier(forIOSVersion: "1.0.3") == nil)
        #expect(tiered.tier(forIOSVersion: "1.0.4")?.stableMinVersion == version("0.64.23"))
        #expect(tiered.tier(forIOSVersion: "1.0.9")?.stableMinVersion == version("0.64.23"))
        #expect(tiered.tier(forIOSVersion: "1.1.0")?.stableMinVersion == version("0.65.0"))
        #expect(tiered.tier(forIOSVersion: "2.0")?.stableMinVersion == version("0.65.0"))
    }

    @Test func boundedTierCoversItsRangeAndFailsOpenAbove() {
        // min "1.0" + max "1.0.99" captures every 1.0.x patch without
        // listing them; versions above the bound get no limit.
        let bounded = MobileMacCompatPolicy(tiers: [
            MobileMacCompatPolicy.Tier(
                minIOSVersion: version("1.0"),
                maxIOSVersion: version("1.0.99"),
                stableMinVersion: version("0.64.23"),
                nightly: nil
            ),
        ])
        #expect(bounded.tier(forIOSVersion: "1.0.0") != nil)
        #expect(bounded.tier(forIOSVersion: "1.0.42") != nil)
        #expect(bounded.tier(forIOSVersion: "1.0.99") != nil)
        #expect(bounded.tier(forIOSVersion: "1.1") == nil)
        #expect(bounded.violation(iosVersion: "1.1", channel: .stable, macAppVersion: nil) == nil)
    }

    @Test func pinpointTierMatchesExactlyOneVersion() {
        let pinpoint = MobileMacCompatPolicy(tiers: [
            MobileMacCompatPolicy.Tier(
                minIOSVersion: version("1.0.4"),
                maxIOSVersion: version("1.0.4"),
                stableMinVersion: version("0.64.23"),
                nightly: nil
            ),
        ])
        #expect(pinpoint.tier(forIOSVersion: "1.0.4") != nil)
        #expect(pinpoint.tier(forIOSVersion: "1.0.3") == nil)
        #expect(pinpoint.tier(forIOSVersion: "1.0.5") == nil)
    }

    @Test func decodeReadsOptionalMaxIOSVersion() throws {
        let payload = Data("""
        {"entries":[{"minIOSVersion":"1.0","maxIOSVersion":"1.0.99","stableMinVersion":"0.64.23"}]}
        """.utf8)
        let decoded = try #require(MobileMacCompatPolicy.decode(payload))
        #expect(decoded.tiers.first?.maxIOSVersion == version("1.0.99"))
        let badMax = Data(#"{"entries":[{"minIOSVersion":"1.0","maxIOSVersion":"x","stableMinVersion":"0.64.23"}]}"#.utf8)
        #expect(MobileMacCompatPolicy.decode(badMax) == nil)
    }

    @Test func tierSelectionFailsOpenForUnparseableAppVersion() {
        // Test fixtures report an empty stamp; the gate must stay out of
        // their way rather than treating "" as version zero.
        #expect(policy.tier(forIOSVersion: "") == nil)
        #expect(policy.tier(forIOSVersion: "dev") == nil)
    }

    // MARK: - Channel resolution

    @Test func releaseLanesAreConstrained() {
        #expect(MobileMacCompatPolicy.constrainedChannel(instanceTag: "default") == .stable)
        #expect(MobileMacCompatPolicy.constrainedChannel(instanceTag: "nightly") == .nightly)
        // Pre-0.64.18 releases report no tag and are the oldest stable lane.
        #expect(MobileMacCompatPolicy.constrainedChannel(instanceTag: nil) == .stable)
        #expect(MobileMacCompatPolicy.constrainedChannel(instanceTag: " ") == .stable)
    }

    @Test(arguments: ["rc", "staging", "dev", "minmac"])
    func nonReleaseLanesAreOutsideThePolicy(_ tag: String) {
        #expect(MobileMacCompatPolicy.constrainedChannel(instanceTag: tag) == nil)
    }

    // MARK: - Stable-channel violations

    @Test func stableMacAtOrAboveMinimumIsAdmitted() {
        #expect(policy.violation(iosVersion: "1.0.4", channel: .stable, macAppVersion: "0.64.23") == nil)
        #expect(policy.violation(iosVersion: "1.0.4", channel: .stable, macAppVersion: "0.65.0") == nil)
    }

    @Test func stableMacBelowMinimumIsRefusedWithVersions() {
        let violation = policy.violation(
            iosVersion: "1.0.4",
            channel: .stable,
            macAppVersion: "0.64.22"
        )
        #expect(violation?.macAppVersion == "0.64.22")
        #expect(violation?.requiredVersionDisplay == "0.64.23")
        #expect(violation?.channel == .stable)
    }

    @Test func stableMacWithoutReportedVersionIsRefused() {
        // Every Mac release the policy can name reports its version, so a
        // missing version proves the Mac predates the minimum.
        let violation = policy.violation(iosVersion: "1.0.4", channel: .stable, macAppVersion: nil)
        #expect(violation != nil)
        #expect(violation?.macAppVersion == nil)
        let blank = policy.violation(iosVersion: "1.0.4", channel: .stable, macAppVersion: "  ")
        #expect(blank?.macAppVersion == nil)
    }

    @Test func nightlyStampOnStableChannelIsRefused() {
        let violation = policy.violation(
            iosVersion: "1.0.4",
            channel: .stable,
            macAppVersion: "0.64.23-nightly.200"
        )
        #expect(violation != nil)
    }

    @Test func appBelowEveryTierIsUnconstrained() {
        #expect(policy.violation(iosVersion: "1.0.3", channel: .stable, macAppVersion: "0.1.0") == nil)
        #expect(policy.violation(iosVersion: "1.0.3", channel: .nightly, macAppVersion: nil) == nil)
    }

    // MARK: - Nightly-channel violations

    @Test func nightlyAtOrAboveMinimumBuildIsAdmitted() {
        #expect(policy.violation(
            iosVersion: "1.0.4", channel: .nightly, macAppVersion: "0.64.22-nightly.100"
        ) == nil)
        #expect(policy.violation(
            iosVersion: "1.0.4", channel: .nightly, macAppVersion: "0.64.22-nightly.101"
        ) == nil)
    }

    @Test func nightlyWithNewerBaseIsAdmittedRegardlessOfBuild() {
        // After a release bumps main's marketing version, nightly counters
        // keep rising but the base alone already proves recency.
        #expect(policy.violation(
            iosVersion: "1.0.4", channel: .nightly, macAppVersion: "0.64.23-nightly.1"
        ) == nil)
    }

    @Test func nightlyBelowMinimumBuildIsRefused() {
        let violation = policy.violation(
            iosVersion: "1.0.4",
            channel: .nightly,
            macAppVersion: "0.64.22-nightly.99"
        )
        #expect(violation?.channel == .nightly)
        #expect(violation?.macAppVersion == "0.64.22-nightly.99")
        #expect(violation?.requiredVersionDisplay == "0.64.22-nightly.100")
    }

    @Test func nightlyWithOlderBaseIsRefused() {
        #expect(policy.violation(
            iosVersion: "1.0.4", channel: .nightly, macAppVersion: "0.64.21-nightly.500"
        ) != nil)
    }

    @Test func releasedStampOnNightlyChannelIsRefused() {
        // An equal base with no counter cannot prove it meets the minimum
        // build, so it fails closed.
        #expect(policy.violation(
            iosVersion: "1.0.4", channel: .nightly, macAppVersion: "0.64.22"
        ) != nil)
    }

    @Test func tierWithoutNightlyRequirementLeavesNightlyUnconstrained() {
        let stableOnly = MobileMacCompatPolicy(tiers: [
            MobileMacCompatPolicy.Tier(
                minIOSVersion: version("1.0.4"),
                stableMinVersion: version("0.64.23"),
                nightly: nil
            ),
        ])
        #expect(stableOnly.violation(
            iosVersion: "1.0.4", channel: .nightly, macAppVersion: "0.1.0-nightly.1"
        ) == nil)
    }

    // MARK: - Remote payload decoding

    @Test func decodesTheEndpointPayload() throws {
        let payload = Data("""
        {"downloads":{"stable":"https://example.com/x.dmg","nightly":"https://example.com/n"},\
        "entries":[{"minIOSVersion":"1.0.4","stableMinVersion":"0.64.23",\
        "nightly":{"minBaseVersion":"0.64.22","minBuild":"3345650013202"}}]}
        """.utf8)
        let decoded = try #require(MobileMacCompatPolicy.decode(payload))
        #expect(decoded.tiers.count == 1)
        #expect(decoded.tiers.first?.stableMinVersion == version("0.64.23"))
        #expect(decoded.tiers.first?.nightly?.minBuild == 3_345_650_013_202)
    }

    @Test func decodeRejectsPartiallyParseablePayloads() {
        // Dropping an unparseable entry could silently weaken the
        // constraint, so the whole payload is discarded instead.
        let badVersion = Data(#"{"entries":[{"minIOSVersion":"x","stableMinVersion":"0.64.23"}]}"#.utf8)
        #expect(MobileMacCompatPolicy.decode(badVersion) == nil)
        let badBuild = Data("""
        {"entries":[{"minIOSVersion":"1.0.4","stableMinVersion":"0.64.23",\
        "nightly":{"minBaseVersion":"0.64.22","minBuild":"12a"}}]}
        """.utf8)
        #expect(MobileMacCompatPolicy.decode(badBuild) == nil)
        #expect(MobileMacCompatPolicy.decode(Data("not json".utf8)) == nil)
    }

    @Test func decodeIgnoresUnknownFields() throws {
        let payload = Data("""
        {"entries":[{"minIOSVersion":"1.0.4","stableMinVersion":"0.64.23","future":true}],"extra":1}
        """.utf8)
        let decoded = try #require(MobileMacCompatPolicy.decode(payload))
        #expect(decoded.tiers.count == 1)
    }

    // MARK: - Baked fallback

    @Test func bakedPolicyConstrainsEveryCurrentLaneToNextReleases() {
        // The App Store lane ships as 1.0.0 and the beta lane as 1.0.4;
        // both must fall inside the first tier.
        for appVersion in ["1.0.0", "1.0.4"] {
            let tier = MobileMacCompatPolicy.baked.tier(forIOSVersion: appVersion)
            #expect(tier?.stableMinVersion == version("0.64.23"))
            #expect(tier?.nightly?.minBuild == 3_345_650_013_202)
        }
        // Versions below the first tier stay unconstrained.
        #expect(MobileMacCompatPolicy.baked.tier(forIOSVersion: "0.9.9") == nil)
    }

    // MARK: - Fail-open when the server does not cover this app version

    @Test func emptyServerListLiftsEveryConstraint() throws {
        // A fetched empty list means the server sets no limit for anyone:
        // no tier matches, so every Mac is admitted. Better than accidentally
        // accepting none.
        let decoded = try #require(MobileMacCompatPolicy.decode(Data(#"{"entries":[]}"#.utf8)))
        #expect(decoded.tier(forIOSVersion: "1.0.4") == nil)
        #expect(decoded.violation(iosVersion: "1.0.4", channel: .stable, macAppVersion: nil) == nil)
        #expect(decoded.violation(iosVersion: "1.0.4", channel: .nightly, macAppVersion: "0.1.0") == nil)
    }

    @Test func uncoveredAppVersionHasNoMacVersionLimit() {
        // The server's tiers start above this app version: no limit applies,
        // even to a Mac with no reported version at all.
        let future = MobileMacCompatPolicy(tiers: [
            MobileMacCompatPolicy.Tier(
                minIOSVersion: version("2.0"),
                stableMinVersion: version("0.99.0"),
                nightly: nil
            ),
        ])
        #expect(future.violation(iosVersion: "1.0.4", channel: .stable, macAppVersion: nil) == nil)
        #expect(future.violation(iosVersion: "1.0.4", channel: .stable, macAppVersion: "0.1.0") == nil)
    }

    // MARK: - Failure copy

    @Test func versionTooOldCopyNamesBothVersions() {
        let category = MobilePairingFailureCategory.macAppVersionTooOld(
            macVersion: "0.64.22",
            requiredVersion: "0.64.23",
            isNightlyChannel: false
        )
        #expect(category.message.contains("0.64.22"))
        #expect(category.message.contains("0.64.23"))
        #expect(category.guidance?.isEmpty == false)
        #expect(category.analyticsReason == "mac_app_version_too_old")
    }

    @Test func versionTooOldCopyHandlesUnknownMacVersion() {
        let category = MobilePairingFailureCategory.macAppVersionTooOld(
            macVersion: nil,
            requiredVersion: "0.64.23",
            isNightlyChannel: false
        )
        #expect(category.message.contains("0.64.23"))
    }

    @Test func versionTooOldCopyOnNightlyChannelAsksForNewerNightly() {
        let category = MobilePairingFailureCategory.macAppVersionTooOld(
            macVersion: "0.64.22-nightly.99",
            requiredVersion: "0.64.22-nightly.100",
            isNightlyChannel: true
        )
        #expect(category.message.contains("Nightly"))
        #expect(category.message.contains("0.64.22-nightly.99"))
    }

    @Test func versionGateRPCCodeFallsBackToGenericUpdateCategory() {
        let category = MobilePairingFailureCategory.classify(
            error: MobileShellConnectionError.rpcError(
                "mac_app_version_too_old",
                "Mac app version is below this iOS build's minimum"
            ),
            route: nil
        )
        #expect(category == .macUpdateRequired)
    }
}
