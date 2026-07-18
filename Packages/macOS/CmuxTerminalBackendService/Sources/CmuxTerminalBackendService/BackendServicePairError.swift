public import Foundation

/// Fail-closed validation and lifecycle errors for immutable backend pairs.
public enum BackendServicePairError: Error, Equatable, Sendable {
    case missingArtifact(URL)
    case symbolicLink(URL)
    case notRegularFile(URL)
    case notDirectory(URL)
    case wrongOwner(URL, expected: UInt32, actual: UInt32)
    case unsafePermissions(URL, mode: UInt16)
    case notExecutable(URL)
    case invalidBuildID(URL, value: String)
    case buildIDMismatch(expected: String, actual: String, URL)
    case executableBuildIDMismatch(expected: String, actual: String)
    case buildIDProbeTimedOut(URL)
    case invalidCodeSignature(URL)
    case invalidManifest(URL)
    case manifestIdentityMismatch(expected: String, actual: String)
    case manifestHashMismatch(URL, expected: String, actual: String)
    case manifestSizeMismatch(URL, expected: UInt64, actual: UInt64)
    case executableOutsideInstallation(URL)
    case installLockBusy(URL)
    case liveServiceReplacementForbidden(active: URL, proposed: URL)
    case loadedDescriptorMissingProgram(String)
    case launchControlFailed(arguments: [String], status: Int32, message: String)
    case launchControlTimedOut(arguments: [String])
}
