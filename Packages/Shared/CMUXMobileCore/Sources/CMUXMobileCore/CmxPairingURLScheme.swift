import Foundation

/// The channel-specific URL scheme carried by cmux pairing/attach deep links.
///
/// All builds used to register and emit one scheme (`cmux-ios`), so scanning a
/// beta/prod pairing QR with the iOS Camera app could open a *dev* build that
/// happened to be installed (the OS picks an arbitrary app when several claim
/// a scheme). The scheme is therefore channel-specific, mirroring how
/// `MobileBuildType` splits channels:
///
/// - **Development (DEBUG)** builds — local Xcode and `reload.sh` tagged
///   builds on both Mac and iPhone — register and emit ``development``.
/// - **Release** builds (TestFlight beta and App Store prod) register and
///   emit ``release``. Beta and prod share a scheme because they are the same
///   compile configuration and a phone realistically has only one of them.
///
/// Emitters (the Mac building a pairing QR or attach URL) use ``current`` so a
/// dev Mac pairs a dev phone and a release Mac pairs a release phone via the
/// system camera. Parsers (the in-app scanner, manual paste, the root scene's
/// deep-link gate) accept *any* pairing scheme via ``isPairingScheme(_:)`` /
/// ``hasPairingScheme(_:)``, so cross-channel pairing still works when the
/// user scans from inside the app.
///
/// The iOS app's registered scheme comes from `CMUX_IOS_URL_SCHEME` in
/// `ios/Config/Shared.xcconfig` (dev) and `ios/Config/Release.xcconfig`
/// (release); keep those values in sync with these constants.
///
/// lint:allow namespace-type — the build channel's URL scheme is a pure
/// compile-time constant set with no per-instance state to inject; these
/// scheme strings and the stateless pairing-scheme predicates are a genuine
/// namespace, like the sanctioned FFI/seam holders.
public struct CmxPairingURLScheme {
    private init() {}

    /// The scheme Release (TestFlight beta + App Store) builds register and emit.
    public static let release = "cmux-ios"

    /// The scheme development (DEBUG/tagged) builds register and emit.
    public static let development = "cmux-ios-dev"

    /// Every scheme any cmux build may emit; parsers accept all of them.
    public static let all: [String] = [release, development]

    /// The scheme this build emits in pairing QRs and attach URLs.
    public static var current: String {
        scheme(isDevelopmentBuild: isDevelopmentBuild)
    }

    /// Pure channel-to-scheme mapping, injected with the compile flag so the
    /// derivation is testable from a single build configuration.
    public static func scheme(isDevelopmentBuild: Bool) -> String {
        isDevelopmentBuild ? development : release
    }

    /// Whether `scheme` is a pairing scheme from any cmux channel.
    public static func isPairingScheme(_ scheme: String?) -> Bool {
        guard let scheme else { return false }
        return all.contains { $0.caseInsensitiveCompare(scheme) == .orderedSame }
    }

    /// Whether `rawValue` starts with any channel's pairing scheme (the
    /// scanner/paste-side prefix check, before URL parsing).
    public static func hasPairingScheme(_ rawValue: String) -> Bool {
        let lowercased = rawValue.lowercased()
        return all.contains { lowercased.hasPrefix($0 + "://") }
    }

    private static var isDevelopmentBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}
