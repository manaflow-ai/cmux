public import Foundation
import Security

/// Which "cmux Computer Use" helper app this build may name, launch or offer
/// for a privacy grant.
///
/// The macOS TCC rows for Accessibility and Screen Recording are keyed by the
/// helper's bundle id (`com.cmuxterm.cua`) and hold the Developer ID
/// requirement of the release helper. An ad-hoc signed copy (a tagged dev
/// build) never satisfies that row, and granting it replaces the row, which
/// breaks the real helper. So every path that picks a helper goes through
/// `resolve`, and only a helper whose signature satisfies `requirement`
/// (identifier + Apple-anchored Developer ID certificate of team
/// `teamIdentifier`) is used. Without one, computer use is unavailable in
/// this build; nothing is installed and nothing is offered for a grant.
public nonisolated struct CuaHelperIdentity: Sendable {
    public static let bundleIdentifier = "com.cmuxterm.cua"
    public static let teamIdentifier = "7WLXT3NR37"
    public static let appName = "cmux Computer Use.app"
    /// The code requirement every usable helper satisfies: the release
    /// helper's designated requirement. The two certificate fields are the
    /// Developer ID intermediate and leaf markers, so an Apple Development or
    /// Apple Distribution signature of the same team does not pass either.
    /// Also in scripts/cmux-cua-helper-trust.sh (shell side of the same rule).
    public static let requirement = "identifier \"\(bundleIdentifier)\" and anchor apple generic"
        + " and certificate 1[field.1.2.840.113635.100.6.2.6]"
        + " and certificate leaf[field.1.2.840.113635.100.6.1.13]"
        + " and certificate leaf[subject.OU] = \"\(teamIdentifier)\""

    /// Why no helper is usable.
    public enum Unavailable: Equatable, Sendable {
        /// The running daemon is a helper copy without the Developer ID signature.
        case runningHelperNotSigned(URL)
        /// No Developer ID signed helper is installed (a release, NIGHTLY or RC cmux).
        case noSignedHelperInstalled
    }

    public enum Resolution: Equatable, Sendable {
        case signed(URL)
        case unavailable(Unavailable)

        public var helperURL: URL? {
            if case .signed(let url) = self { return url }
            return nil
        }
    }

    private let isSigned: @Sendable (URL) -> Bool

    /// `isSigned` decides whether a helper bundle satisfies `requirement`;
    /// tests pass a stand-in, the App uses the code-signature check.
    public init(isSigned: @escaping @Sendable (URL) -> Bool = CuaHelperIdentity.satisfiesRequirement) {
        self.isSigned = isSigned
    }

    /// The helper to use. A running daemon decides when known: it is the
    /// identity that needs the grant, so an unsigned running copy makes
    /// computer use unavailable even when a signed copy is installed
    /// elsewhere. Otherwise the first signed installed candidate.
    public func resolve(running: URL?, installed: [URL]) -> Resolution {
        if let running {
            return isSigned(running) ? .signed(running) : .unavailable(.runningHelperNotSigned(running))
        }
        if let signed = installed.first(where: isSigned) { return .signed(signed) }
        return .unavailable(.noSignedHelperInstalled)
    }

    /// Whether the bundle at `url` is a helper with the Developer ID signature.
    /// Reads the bundle's signature on disk (no launch, no prompt): it must
    /// be valid, strict, for every architecture, and satisfy `requirement`.
    /// An ad-hoc signature has no certificate, so it never passes.
    public static func satisfiesRequirement(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var compiled: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess,
              let compiled else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, compiled) == errSecSuccess
    }

    /// Where an installed release helper can be, most preferred first. A
    /// release build: its own nested helper, then the installed apps. A dev
    /// build (its own helper is ad hoc): NIGHTLY, then RC, then the release
    /// app, in /Applications and ~/Applications; NIGHTLY first because it is
    /// closest to the dev build and is the copy that holds the grants on the
    /// team's machines. Only installed apps count, not every copy
    /// LaunchServices knows (old downloads, DMGs, DerivedData). Unsigned
    /// copies stay in the list; `resolve` filters them.
    public static func installedCandidates(mainBundle: URL = Bundle.main.bundleURL,
                                           home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                           isDevBuild: Bool) -> [URL] {
        let own = mainBundle.appending(path: "Contents/Library/\(appName)")
        let apps = ["cmux.app", "cmux NIGHTLY.app", "cmux RC.app"]
        var candidates = [own]
        for root in [URL(fileURLWithPath: "/Applications"), home.appending(path: "Applications")] {
            for app in apps {
                candidates.append(root.appending(path: "\(app)/Contents/Library/\(appName)"))
            }
            candidates.append(root.appending(path: appName))
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}
