public import Foundation

/// Pins the signing identity that the enclosing app bundle and its privileged helpers must carry.
///
/// Every bundled file handed to `sudo` is authenticated against this policy first: the bundle's
/// signature is validated against ``bundleRequirement`` and the helper digest is taken from the
/// validated resource seal, never from the user-writable file itself.
public struct SudoBundledHelperPolicy: Sendable, Equatable {
    /// The enclosing `.app` bundle whose seal vouches for the helpers.
    public let appBundleURL: URL
    let bundleRequirement: SudoCodeSigningRequirement?
    let executorRequirement: SudoCodeSigningRequirement

    init(
        appBundleURL: URL,
        bundleRequirement: SudoCodeSigningRequirement?,
        executorRequirement: SudoCodeSigningRequirement
    ) {
        self.appBundleURL = appBundleURL.standardizedFileURL
        self.bundleRequirement = bundleRequirement
        self.executorRequirement = executorRequirement
    }

    /// The release policy: bundle and executor must be Developer ID signed by `teamIdentifier`.
    ///
    /// - Returns: `nil` when the team identifier is malformed.
    public static func developerID(
        appBundleURL: URL,
        teamIdentifier: String
    ) -> SudoBundledHelperPolicy? {
        guard let requirement = SudoCodeSigningRequirement.developerID(
            teamIdentifier: teamIdentifier
        ) else {
            return nil
        }
        return SudoBundledHelperPolicy(
            appBundleURL: appBundleURL,
            bundleRequirement: requirement,
            executorRequirement: requirement
        )
    }

    /// The debug-build policy: helpers must carry the running CLI's own signing identity.
    ///
    /// The staged executor must satisfy the running code's designated requirement (its cdhash for
    /// an ad-hoc build). A team-signed debug bundle must also be signed by the same team; an ad-hoc
    /// bundle is still required to have an intact resource seal.
    ///
    /// - Returns: `nil` when the running process has no valid signature.
    public static func runningCodeIdentity(appBundleURL: URL) -> SudoBundledHelperPolicy? {
        runningCodeIdentity(
            appBundleURL: appBundleURL,
            reader: SystemSudoRunningCodeIdentityReader()
        )
    }

    static func runningCodeIdentity(
        appBundleURL: URL,
        reader: any SudoRunningCodeIdentityReading
    ) -> SudoBundledHelperPolicy? {
        guard let designatedRequirement = try? reader.designatedRequirement() else {
            return nil
        }
        let bundleRequirement: SudoCodeSigningRequirement?
        if let teamIdentifier = reader.teamIdentifier(), !teamIdentifier.isEmpty {
            guard let requirement = SudoCodeSigningRequirement.appleTeam(
                teamIdentifier: teamIdentifier
            ) else {
                return nil
            }
            bundleRequirement = requirement
        } else {
            bundleRequirement = nil
        }
        return SudoBundledHelperPolicy(
            appBundleURL: appBundleURL,
            bundleRequirement: bundleRequirement,
            executorRequirement: designatedRequirement
        )
    }
}
