public import Foundation
import Security

/// ``AppSignatureInspecting`` backed by the Security framework's static code APIs.
public struct SecurityAppSignatureInspector: AppSignatureInspecting {
    /// Why the Security framework could not inspect a bundle at all.
    public struct InspectionError: Error, Equatable, Sendable {
        /// The `OSStatus` the failing call returned.
        public let status: Int32
    }

    /// Creates an inspector.
    public init() {}

    public func inspect(appURL: URL, teamIdentifier: String) throws -> AppSignatureReport {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            throw InspectionError(status: createStatus)
        }

        var requirement: SecRequirement?
        let requirementText = AppSignatureVerifier.developerIDRequirement(teamIdentifier: teamIdentifier)
        let requirementStatus = SecRequirementCreateWithString(requirementText as CFString, [], &requirement)
        guard requirementStatus == errSecSuccess, let requirement else {
            throw InspectionError(status: requirementStatus)
        }

        let validityFlags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let validity = SecStaticCodeCheckValidityWithErrors(staticCode, validityFlags, requirement, nil)

        var information: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        )
        let signing = informationStatus == errSecSuccess ? (information as? [String: Any]) ?? [:] : [:]

        return AppSignatureReport(
            bundleIdentifier: Self.infoPlistBundleIdentifier(appURL: appURL),
            signingIdentifier: signing[kSecCodeInfoIdentifier as String] as? String,
            teamIdentifier: signing[kSecCodeInfoTeamIdentifier as String] as? String,
            satisfiesDeveloperIDRequirement: validity == errSecSuccess
        )
    }

    /// Reads `CFBundleIdentifier` straight from `Contents/Info.plist`, bypassing `Bundle`'s
    /// per-path cache so a replaced bundle is never reported with stale values.
    static func infoPlistBundleIdentifier(appURL: URL) -> String? {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["CFBundleIdentifier"] as? String
    }
}
