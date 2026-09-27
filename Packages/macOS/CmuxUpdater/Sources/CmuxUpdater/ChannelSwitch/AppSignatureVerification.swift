public import Foundation

/// What a code-signature inspection found for one app bundle.
public struct AppSignatureReport: Equatable, Sendable {
    /// `CFBundleIdentifier` from the bundle's `Info.plist`.
    public var bundleIdentifier: String?
    /// The identifier sealed into the code signature.
    public var signingIdentifier: String?
    /// The Developer ID team that signed the bundle.
    public var teamIdentifier: String?
    /// Whether the whole bundle, nested code included, validates against a Developer ID
    /// Application requirement for the expected team.
    public var satisfiesDeveloperIDRequirement: Bool

    /// Creates a report.
    public init(
        bundleIdentifier: String?,
        signingIdentifier: String?,
        teamIdentifier: String?,
        satisfiesDeveloperIDRequirement: Bool
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
        self.satisfiesDeveloperIDRequirement = satisfiesDeveloperIDRequirement
    }
}

/// Reads the code signature of an app bundle on disk.
public protocol AppSignatureInspecting: Sendable {
    /// Inspects `appURL`, validating the signature against a Developer ID requirement for
    /// `teamIdentifier`.
    func inspect(appURL: URL, teamIdentifier: String) throws -> AppSignatureReport
}

/// Why a downloaded app was refused.
public enum AppSignatureVerificationFailure: Error, Equatable, Sendable {
    /// The signature is broken, incomplete, or not a Developer ID Application signature.
    case invalidSignature
    /// Signed by another team.
    case unexpectedTeam(String?)
    /// `Info.plist` or the signature names another bundle identifier.
    case unexpectedBundleIdentifier(String?)
}

/// The rules a downloaded cmux app must pass before it is installed.
public struct AppSignatureVerifier: Sendable {
    /// The Developer ID team the app must be signed by.
    public let teamIdentifier: String

    /// Creates a verifier for `teamIdentifier`.
    public init(teamIdentifier: String = AppChannelSwitchTarget.developerTeamIdentifier) {
        self.teamIdentifier = teamIdentifier
    }

    /// Throws unless `report` describes a valid Developer ID signature by the expected team
    /// for `bundleIdentifier`, in both `Info.plist` and the signature itself.
    public func verify(_ report: AppSignatureReport, bundleIdentifier: String) throws {
        guard report.satisfiesDeveloperIDRequirement else {
            throw AppSignatureVerificationFailure.invalidSignature
        }
        guard report.teamIdentifier == teamIdentifier else {
            throw AppSignatureVerificationFailure.unexpectedTeam(report.teamIdentifier)
        }
        guard report.bundleIdentifier == bundleIdentifier else {
            throw AppSignatureVerificationFailure.unexpectedBundleIdentifier(report.bundleIdentifier)
        }
        guard report.signingIdentifier == bundleIdentifier else {
            throw AppSignatureVerificationFailure.unexpectedBundleIdentifier(report.signingIdentifier)
        }
    }

    /// The designated-requirement text for a Developer ID Application signature by `teamIdentifier`.
    ///
    /// Anchored at Apple, with the Developer ID intermediate
    /// (`1.2.840.113635.100.6.2.6`) and the Developer ID Application leaf marker
    /// (`1.2.840.113635.100.6.1.13`), and the team in the leaf's organizational unit.
    public static func developerIDRequirement(teamIdentifier: String) -> String {
        "anchor apple generic"
            + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
            + " and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }
}
