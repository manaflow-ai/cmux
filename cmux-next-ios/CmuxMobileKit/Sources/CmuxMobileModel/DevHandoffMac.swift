import Foundation
import Synchronization

/// The Mac build a tagged dev build's pairing code named: the build this
/// phone lists, focuses and links for that Mac's computer (``MacRoster``).
/// DEBUG builds with a `dev.cmux.mobile.<tag>` bundle id only.
///
/// Every cmux build on one computer is its own Mac on the account, and a
/// developer runs several tagged Mac builds at once. ``MacRoster`` lists one
/// per computer, and of several online builds it lists the lowest device id.
/// The end-of-task hand-off (`cmux-next-ios/scripts/review.sh`) launches a
/// tag's phone app with its own tag's Mac's pairing code, so before this the
/// phone dialed that Mac only while the code was held. It focused, and kept,
/// whichever other tag's build had the lowest id. The Mac list carries no
/// build identity, so the code's Mac is the phone's only sign of its own
/// tag's Mac. It is remembered across launches, so a credential-free relaunch
/// keeps the same Mac.
///
/// Release, Production, TestFlight and App Store builds never prefer a build:
/// ``macID`` is nil there, and the roster lists as it always did.
public final class DevHandoffMac: Sendable {
    /// This app's (the running bundle's).
    public static let current = DevHandoffMac(bundleID: Bundle.main.bundleIdentifier)

    static let key = "cmuxMobile.dev.handoffMac"

    private let enabled: Bool
    /// The defaults suite (nil: the standard defaults).
    private let suiteName: String?
    /// The remembered id, read from the defaults once.
    private let cached = Mutex<String??>(nil)

    /// For `bundleID`: on only in a DEBUG build of a tagged dev bundle.
    public convenience init(bundleID: String?) {
        #if DEBUG
        self.init(enabled: Self.isTaggedDevBuild(bundleID), suiteName: nil)
        #else
        self.init(enabled: false, suiteName: nil)
        #endif
    }

    /// Tests: a preference that is on or off, kept in its own defaults suite.
    public init(enabled: Bool, suiteName: String?) {
        self.enabled = enabled
        self.suiteName = suiteName
    }

    /// A tagged dev phone app: `dev.cmux.mobile.<tag>`.
    public static func isTaggedDevBuild(_ bundleID: String?) -> Bool {
        let prefix = "dev.cmux.mobile."
        guard let bundleID, bundleID.hasPrefix(prefix) else { return false }
        return !bundleID.dropFirst(prefix.count).isEmpty
    }

    /// The Mac to prefer among its computer's builds, or nil.
    public var macID: String? {
        guard enabled else { return nil }
        return cached.withLock { value in
            if let value { return value }
            let read = defaults.string(forKey: Self.key).flatMap { $0.isEmpty ? nil : $0 }
            value = .some(read)
            return read
        }
    }

    /// A pairing code for `macID` was taken: prefer that build from now on.
    public func remember(_ macID: String) {
        guard enabled, !macID.isEmpty else { return }
        cached.withLock { value in
            guard value != .some(macID) else { return }
            value = .some(macID)
            defaults.set(macID, forKey: Self.key)
        }
    }

    private var defaults: UserDefaults {
        suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }
}
