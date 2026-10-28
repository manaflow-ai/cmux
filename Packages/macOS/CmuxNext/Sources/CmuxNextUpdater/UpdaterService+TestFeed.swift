import CmuxUpdater
import Foundation

/// "Use Test Update Feed" (coordinator 2026-10-04): DEV and NIGHTLY builds
/// may read a test appcast instead of the baked feed. Sparkle still checks
/// every item against the app's own EdDSA key, so a test feed can only
/// offer builds signed with that key, and only a build newer than the running
/// one (Sparkle's standard version order). The feed shows in the card stack
/// and `updates.status` while active, and ends with the process unless pinned.
/// On NIGHTLY, which installs what the feed offers, only the person turns a
/// test feed on: a request asks them first (``testFeedRequest(url:track:)``).
extension UpdaterService {
    /// What a request to change the test feed does.
    public enum TestFeedRequest: Sendable, Equatable {
        /// Change it now.
        case apply
        /// Ask the person first; change it only on their yes.
        case askFirst
        /// Not on this build, or not an accepted feed address.
        case refuse
    }

    /// A request for `url` (nil: back to the real feed) on a `track` build.
    public nonisolated static func testFeedRequest(url: String?, track: UpdateTrack) -> TestFeedRequest {
        guard track == .nightly || track == .development else { return .refuse }
        guard let url else { return .apply }
        guard acceptsTestFeed(url) else { return .refuse }
        return track == .nightly ? .askFirst : .apply
    }

    /// The pinned test feed, read once at launch. A pin is written only after
    /// the person's yes on NIGHTLY (the `.v2` key); pins of earlier builds,
    /// which any socket client could set, are dropped at launch.
    static let pinnedTestFeedKey = "cmux.next.updates.testFeedURL.v2"
    static let unconfirmedPinnedTestFeedKey = "cmux.next.updates.testFeedURL"

    /// Uses `url` (nil clears) for every check until relaunch, or until
    /// cleared when `pinned`.
    public func useTestFeed(_ url: String?, pinned: Bool) throws {
        guard identity.track == .nightly || identity.track == .development else {
            throw UpdaterUnavailable.testFeedRefused
        }
        guard let url else {
            testFeedURL = nil
            defaults.removeObject(forKey: Self.pinnedTestFeedKey)
            controller?.feedOverride = nil
            log.append("test feed cleared")
            return
        }
        guard Self.acceptsTestFeed(url) else { throw UpdaterUnavailable.testFeedRefused }
        testFeedURL = url
        if pinned {
            defaults.set(url, forKey: Self.pinnedTestFeedKey)
        } else {
            defaults.removeObject(forKey: Self.pinnedTestFeedKey)
        }
        controller?.feedOverride = url
        log.append("test feed \(url)\(pinned ? " (pinned)" : "")")
    }

    /// https anywhere, or http on a loopback host (a local test server).
    nonisolated static func acceptsTestFeed(_ text: String) -> Bool {
        guard let url = URL(string: text), let host = url.host?.lowercased(), !host.isEmpty else { return false }
        switch url.scheme?.lowercased() {
        case "https": return true
        case "http": return ["127.0.0.1", "localhost", "::1"].contains(host)
        default: return false
        }
    }

    /// The question a NIGHTLY build asks before it uses the test feed `url`
    /// (``TestFeedRequest/askFirst``): its title, body (naming the feed's
    /// host), and the use and cancel button titles.
    public nonisolated static func testFeedConfirmation(url: String, pinned: Bool)
        -> (title: String, body: String, use: String, cancel: String) {
        let host = URL(string: url)?.host ?? url
        return (UpdaterStrings.testFeedConfirmTitle,
                pinned ? UpdaterStrings.testFeedConfirmPinnedBody(host) : UpdaterStrings.testFeedConfirmBody(host),
                UpdaterStrings.testFeedConfirmUse, UpdaterStrings.testFeedConfirmCancel)
    }

    /// The card that shows while a test feed is active: title, the feed's
    /// host, and the button that returns to the real feed.
    public var testFeedCardText: (title: String, detail: String, useRealFeed: String)? {
        guard let testFeedURL else { return nil }
        return (UpdaterStrings.testFeedTitle, URL(string: testFeedURL)?.host ?? testFeedURL, UpdaterStrings.testFeedUseReal)
    }

    /// What a pin found at launch does: any process of this user can write
    /// the app's defaults, so on NIGHTLY (which installs what the feed
    /// offers) a pin applies only after the person's yes again; DEV applies
    /// it (it never installs).
    public nonisolated static func pinnedTestFeedAtLaunch(track: UpdateTrack) -> TestFeedRequest {
        switch track {
        case .nightly: .askFirst
        case .development: .apply
        case .stable, .rc: .refuse
        }
    }

    /// Restores a pinned test feed at launch (DEV), or holds it for the
    /// person's yes (NIGHTLY, ``pinnedTestFeedAwaitingConsent``).
    func restorePinnedTestFeed() {
        defaults.removeObject(forKey: Self.unconfirmedPinnedTestFeedKey)
        guard let pinned = defaults.string(forKey: Self.pinnedTestFeedKey), Self.acceptsTestFeed(pinned) else { return }
        switch Self.pinnedTestFeedAtLaunch(track: identity.track) {
        case .apply:
            testFeedURL = pinned
            controller?.feedOverride = pinned
        case .askFirst:
            pinnedTestFeedAwaitingConsent = pinned
        case .refuse:
            defaults.removeObject(forKey: Self.pinnedTestFeedKey)
        }
    }

    /// The person answered the launch question about a held pin: yes applies
    /// it (kept pinned), no clears it.
    public func answerPinnedTestFeed(_ yes: Bool) {
        guard let pinned = pinnedTestFeedAwaitingConsent else { return }
        pinnedTestFeedAwaitingConsent = nil
        if yes { try? useTestFeed(pinned, pinned: true) } else { defaults.removeObject(forKey: Self.pinnedTestFeedKey) }
    }
}

extension UpdaterUnavailable {
    public static var testFeedRefused: UpdaterUnavailable { UpdaterUnavailable(text: UpdaterStrings.testFeedRefused) }
}
