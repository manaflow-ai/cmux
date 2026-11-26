public import Foundation
import Security

/// Checks a pack item with `SecStaticCodeCheckValidity`: strict validation,
/// every architecture, nested code (a helper app's executable, the
/// framework's libraries), against the requirement
/// `anchor apple generic and certificate leaf[subject.OU] = "<team>"`
/// (a Developer ID certificate of that team).
public struct SecCodeChromiumRuntimeSignatureChecker: ChromiumRuntimeSignatureChecking {
    /// Creates a checker.
    public init() {}

    public func check(_ item: URL, teamID: String) async throws(ChromiumRuntimeInstallError) {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(item as CFURL, [], &code) == errSecSuccess, let code else {
            throw .signature(item.lastPathComponent)
        }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            throw .signature("requirement for \(teamID)")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        // concurrency-allow: the ChromiumRuntimeInstaller actor calls it during an install, never main
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw .signature(item.lastPathComponent)
        }
    }
}
