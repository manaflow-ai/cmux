import Foundation
import Security

/// Decides which "cmux Computer Use" helper this build may install and launch.
///
/// The Accessibility and Screen Recording rows for `com.cmuxterm.cua` hold the
/// Developer ID requirement of the release helper. An ad-hoc signed copy (what
/// a tagged dev build bundles) can never satisfy those rows, and granting one
/// replaces the row, which breaks the release helper. So the runtime installs
/// only a helper whose signature satisfies ``requirementText``: its own nested
/// helper when that is Developer ID signed (release builds), otherwise the
/// helper of an installed cmux NIGHTLY, RC or release app. With neither,
/// Computer Use is unavailable in this build: nothing is installed or launched,
/// so macOS never shows a permission prompt for an ad-hoc identity.
public struct ComputerUseHelperTrust: Sendable {
    /// The helper's bundle identifier, the key of its TCC rows.
    public static let bundleIdentifier = "com.cmuxterm.cua"
    /// The Developer ID team that signs release helpers.
    public static let teamIdentifier = "7WLXT3NR37"
    /// The code requirement every usable helper satisfies: the release
    /// helper's designated requirement. The two certificate fields are the
    /// Developer ID intermediate and leaf markers, so an Apple Development or
    /// Distribution signature of the same team does not pass either.
    static let requirementText = "identifier \"\(bundleIdentifier)\" and anchor apple generic"
        + " and certificate 1[field.1.2.840.113635.100.6.2.6]"
        + " and certificate leaf[field.1.2.840.113635.100.6.1.13]"
        + " and certificate leaf[subject.OU] = \"\(teamIdentifier)\""

    private let isSigned: @Sendable (URL) -> Bool
    private let installedCandidates: @Sendable () -> [URL]

    /// The production trust: the on-disk signature check and the installed release apps.
    public init() {
        self.init(
            isSigned: Self.satisfiesRequirement,
            installedCandidates: {
                Self.releaseCandidates(home: FileManager.default.homeDirectoryForCurrentUser)
            }
        )
    }

    /// A trust with an injected signature check and candidate list, for tests.
    init(
        isSigned: @escaping @Sendable (URL) -> Bool,
        installedCandidates: @escaping @Sendable () -> [URL]
    ) {
        self.isSigned = isSigned
        self.installedCandidates = installedCandidates
    }

    /// The helper bundle to copy into this build's helper directory, or nil
    /// when no Developer ID signed helper is available. Reads signatures on
    /// disk, so callers run it off the main actor.
    func installSource(nested: URL?) -> URL? {
        if let nested, isSigned(nested) { return nested }
        return installedCandidates().first { candidate in
            candidate.standardizedFileURL != nested?.standardizedFileURL && isSigned(candidate)
        }
    }

    /// Whether `url` is a Developer ID signed helper this build may launch.
    func isTrusted(_ url: URL) -> Bool {
        isSigned(url)
    }

    /// Reads the bundle's signature on disk (no launch, no prompt). It must be
    /// valid for every architecture and nested code and satisfy
    /// ``requirementText``. An ad-hoc signature has no certificate, so it fails.
    static func satisfiesRequirement(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            return false
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    /// Where an installed release helper can be, most preferred first: the
    /// nested helpers of cmux NIGHTLY (closest to main), RC and release in
    /// `/Applications` and `~/Applications`. Only installed apps count, not
    /// every copy LaunchServices knows (old downloads, DMGs, DerivedData).
    /// Unsigned copies stay in the list; the signature check filters them.
    static func releaseCandidates(home: URL) -> [URL] {
        let helper = "Contents/Library/cmux Computer Use.app"
        var candidates: [URL] = []
        for root in [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")] {
            for app in ["cmux NIGHTLY.app", "cmux RC.app", "cmux.app"] {
                candidates.append(root.appendingPathComponent(app).appendingPathComponent(helper))
            }
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}
