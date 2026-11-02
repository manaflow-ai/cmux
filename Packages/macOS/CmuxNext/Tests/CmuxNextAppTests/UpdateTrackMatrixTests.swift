@testable import CmuxNextUpdater
import CmuxUpdater
import Foundation
import Testing

/// Every updater control reads the release line from ``UpdateBuildIdentity/track``. cmux NEXT
/// (`com.cmuxterm.app.nightly.cmux-next`, the `/nightly-next/` feed, its own release and Sparkle
/// key) is its own track, `nightly-next`, not classic NIGHTLY's `nightly`; so are the legacy NEXT
/// build signed as cmux NIGHTLY and the tip app, which read `/nightly-next/` feeds too. Each
/// control below is pinned for every release identity: the track on the wire (`updates.status`),
/// the channel label, test-feed availability, the managed `UpdateChannel` it counts under, the
/// channel-switch counterpart and the fast feed check.
@MainActor @Suite struct UpdateTrackMatrixTests {
    /// ``TipUpdateCheck/interval(for:)``: none, a NIGHTLY's, or the tip app's.
    enum FastCheck: Sendable { case off, nightly, tip }

    struct Row: Sendable, CustomTestStringConvertible {
        let name: String
        let bundleIdentifier: String
        let feed: String
        /// `updates.status`'s `track`.
        let track: String
        let label: UpdateTrack
        let testFeed: Bool
        /// The `UpdateChannel` this build is on (`isOffManagedChannel` is false), nil for none.
        let managedChannel: String?
        let switchTarget: AppChannelSwitchTarget?
        let fastCheck: FastCheck
        var testDescription: String { name }
    }

    nonisolated static let rows: [Row] = [
        Row(name: "stable", bundleIdentifier: "com.cmuxterm.app", feed: TipAppTrackTests.stableFeed,
            track: "stable", label: .stable, testFeed: false, managedChannel: "stable", switchTarget: .nightly, fastCheck: .off),
        Row(name: "RC", bundleIdentifier: "com.cmuxterm.app.rc", feed: "https://files.cmux.com/rc/appcast-arm64.xml",
            track: "rc", label: .rc, testFeed: false, managedChannel: "stable", switchTarget: nil, fastCheck: .off),
        Row(name: "classic NIGHTLY", bundleIdentifier: "com.cmuxterm.app.nightly", feed: "https://files.cmux.com/nightly/appcast-arm64.xml",
            track: "nightly", label: .nightly, testFeed: true, managedChannel: "nightly", switchTarget: .stable,
            fastCheck: .nightly),
        Row(name: "cmux NEXT", bundleIdentifier: "com.cmuxterm.app.nightly.cmux-next",
            feed: "https://files-next.cmux.com/nightly-next/next/appcast-arm64.xml",
            track: "nightly-next", label: .nightly, testFeed: true, managedChannel: "nightly", switchTarget: .dev,
            fastCheck: .nightly),
        Row(name: "cmux NEXT signed as cmux NIGHTLY", bundleIdentifier: "com.cmuxterm.app.nightly",
            feed: "https://files-next.cmux.com/nightly-next/appcast-arm64.xml",
            track: "nightly-next", label: .nightly, testFeed: true, managedChannel: "nightly", switchTarget: .stable,
            fastCheck: .nightly),
        Row(name: "tip app", bundleIdentifier: UpdateBuildIdentity.tipBundleIdentifier, feed: TipAppTrackTests.tipFeed,
            track: "nightly-next", label: .nightly, testFeed: true, managedChannel: "nightly", switchTarget: .nightlyNext,
            fastCheck: .tip),
        // A local `reload.sh --tag next` build: the tip app's bundle id with the default feed.
        Row(name: "local NEXT DEV", bundleIdentifier: UpdateBuildIdentity.tipBundleIdentifier, feed: TipAppTrackTests.stableFeed,
            track: "development", label: .development, testFeed: true, managedChannel: nil, switchTarget: nil, fastCheck: .off),
        Row(name: "DEV", bundleIdentifier: "com.cmuxterm.app.debug", feed: TipAppTrackTests.stableFeed,
            track: "development", label: .development, testFeed: true, managedChannel: nil, switchTarget: nil, fastCheck: .off),
    ]

    static func updater(_ row: Row) -> UpdaterService {
        let identity = TipAppTrackTests.identity(row.bundleIdentifier, feed: row.feed)
        let updater = UpdaterService(identity: identity, policy: ManagedUpdatePolicy { false },
                                     defaults: UserDefaults(suiteName: "UpdateTrackMatrixTests.\(UUID().uuidString)")!,
                                     enableSparkle: false, recordsUpdates: false)
        updater.announcementsFetch = false
        return updater
    }

    @Test(arguments: rows)
    func eachReleaseIdentityHasExplicitControls(row: Row) throws {
        let updater = Self.updater(row)
        let identity = updater.identity
        #expect(identity.track.rawValue == row.track, "\(row.name): track")
        #expect(updater.status.track.rawValue == row.track, "\(row.name): updates.status track")
        // NEXT's sheet still says "nightly" (its app is named cmux NEXT); the label is chosen per track.
        #expect(UpdaterStrings.channel(identity.track) == UpdaterStrings.channel(row.label), "\(row.name): channel label")
        #expect(identity.channelSwitchTarget == row.switchTarget, "\(row.name): channel switch counterpart")
        let fastCheck: TimeInterval? = switch row.fastCheck {
        case .off: nil
        case .nightly: TipUpdateCheck.nightlyInterval
        case .tip: TipUpdateCheck.interval
        }
        #expect(TipUpdateCheck.interval(for: identity) == fastCheck, "\(row.name): fast feed check")

        let accepted: Bool
        do {
            try updater.useTestFeed("https://example.com/appcast.xml", pinned: false)
            accepted = true
        } catch {
            accepted = false
        }
        #expect(accepted == row.testFeed, "\(row.name): test feed")
        if accepted { try updater.useTestFeed(nil, pinned: false) }

        for channel in ["stable", "nightly"] {
            updater.applyManagedPolicy(channel: channel, minimumVersion: nil)
            let off = row.managedChannel.map { $0 != channel } ?? false
            #expect(updater.isOffManagedChannel == off, "\(row.name): under UpdateChannel \(channel)")
        }
    }

    /// cmux NEXT and its DEV app switch to each other by name: `dev` from NIGHTLY, `nightly`
    /// (or `nightly-next`) from DEV. Neither reaches classic NIGHTLY or stable.
    @Test func nextAndDevSwitchToEachOtherByName() {
        let next = Self.updater(Self.rows.first { $0.name == "cmux NEXT" }!)
        let tip = Self.updater(Self.rows.first { $0.name == "tip app" }!)
        #expect(next.channelSwitchUnavailableReason == nil)
        #expect(tip.channelSwitchUnavailableReason == nil)
        #expect(throws: UpdaterUnavailable.self) { try next.switchChannel(named: "stable") }
        #expect(throws: UpdaterUnavailable.self) { try next.switchChannel(named: "nightly") }
        #expect(throws: UpdaterUnavailable.self) { try tip.switchChannel(named: "dev") }
        #expect(throws: UpdaterUnavailable.self) { try tip.switchChannel(named: "stable") }
        #expect(AppChannelSwitchTarget.nightlyNext.isNamed("nightly"))
        #expect(AppChannelSwitchTarget.nightlyNext.isNamed("Nightly-Next"))
        #expect(!AppChannelSwitchTarget.dev.isNamed("nightly"))
    }

    /// `UpdateChannel` names stable or nightly: cmux NEXT's NIGHTLY counts as nightly, DEV as
    /// no channel, and a pin to anything else pins nothing.
    @Test func managedChannelGovernsTheNextSwitch() {
        let tip = Self.updater(Self.rows.first { $0.name == "tip app" }!)
        tip.applyManagedPolicy(channel: "nightly", minimumVersion: nil)
        #expect(tip.channelSwitchUnavailableReason == nil)
        tip.applyManagedPolicy(channel: "stable", minimumVersion: nil)
        #expect(tip.channelSwitchUnavailableReason != nil)

        let next = Self.updater(Self.rows.first { $0.name == "cmux NEXT" }!)
        next.applyManagedPolicy(channel: "nightly", minimumVersion: nil)
        #expect(next.channelSwitchUnavailableReason != nil)
        next.applyManagedPolicy(channel: "dev", minimumVersion: nil)
        #expect(next.managedChannel == nil)
        #expect(next.channelSwitchUnavailableReason == nil)
    }

    /// The new track is only a new value: the existing ones keep their wire names.
    @Test func existingTrackNamesAreUnchanged() {
        #expect(UpdateTrack(rawValue: "stable") == .stable)
        #expect(UpdateTrack(rawValue: "nightly") == .nightly)
        #expect(UpdateTrack(rawValue: "rc") == .rc)
        #expect(UpdateTrack(rawValue: "development") == .development)
    }
}
