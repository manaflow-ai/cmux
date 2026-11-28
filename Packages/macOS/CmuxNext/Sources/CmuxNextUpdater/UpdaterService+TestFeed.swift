import CmuxUpdater
import Foundation

/// "Use Test Update Feed" (coordinator 2026-10-04): DEV and NIGHTLY builds
/// may read a test appcast instead of the baked feed. Sparkle still checks
/// every item against the app's own EdDSA key, so a test feed can only
/// offer builds signed with that key. The feed shows in the card stack and
/// `updates.status` while active, and ends with the process unless pinned.
extension UpdaterService {
    /// The pinned test feed, read once at launch.
    static let pinnedTestFeedKey = "cmux.next.updates.testFeedURL"

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
    static func acceptsTestFeed(_ text: String) -> Bool {
        guard let url = URL(string: text), let host = url.host?.lowercased(), !host.isEmpty else { return false }
        switch url.scheme?.lowercased() {
        case "https": return true
        case "http": return ["127.0.0.1", "localhost", "::1"].contains(host)
        default: return false
        }
    }

    /// The card that shows while a test feed is active: title, the feed's
    /// host, and the button that returns to the real feed.
    public var testFeedCardText: (title: String, detail: String, useRealFeed: String)? {
        guard let testFeedURL else { return nil }
        return (UpdaterStrings.testFeedTitle, URL(string: testFeedURL)?.host ?? testFeedURL, UpdaterStrings.testFeedUseReal)
    }

    /// Restores a pinned test feed at launch (DEV and NIGHTLY only).
    func restorePinnedTestFeed() {
        guard identity.track == .nightly || identity.track == .development,
              let pinned = defaults.string(forKey: Self.pinnedTestFeedKey), Self.acceptsTestFeed(pinned) else { return }
        testFeedURL = pinned
        controller?.feedOverride = pinned
    }
}

extension UpdaterUnavailable {
    static var testFeedRefused: UpdaterUnavailable { UpdaterUnavailable(text: UpdaterStrings.testFeedRefused) }
}
