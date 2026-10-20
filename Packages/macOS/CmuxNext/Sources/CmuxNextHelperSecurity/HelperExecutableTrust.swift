import Darwin
public import Foundation
import Security

/// Validates an executable against an immutable signing-team reference.
///
/// A trusted executable is a direct regular file rather than a symbolic link, has a valid strict
/// signature for every architecture, and is Apple-anchored with the expected Team ID. An unsigned
/// running process or invalid reviewed Team ID fails closed.
public struct HelperExecutableTrust: Sendable {
    /// The immutable identity that executable helpers must match.
    public enum Reference: Sendable {
        /// The Team ID of the process currently executing this code, obtained from its live `SecCode`.
        case runningProcess
        /// A reviewed Team ID for an external application's signed helper.
        case teamIdentifier(String)
    }

    private let expectedTeamIdentifier: String?
    private let isDirectRegularFile: @Sendable (URL) -> Bool
    private let validatesCode: @Sendable (URL, String) -> Bool

    /// Creates a trust policy rooted in a live process or reviewed Team ID.
    /// - Parameter reference: The immutable signing identity the helper must match.
    public init(reference: Reference) {
        switch reference {
        case .runningProcess:
            expectedTeamIdentifier = Self.runningProcessTeamIdentifier()
        case .teamIdentifier(let team):
            expectedTeamIdentifier = Self.isRequirementLiteral(team) ? team : nil
        }
        isDirectRegularFile = Self.isDirectRegularFile
        validatesCode = Self.validatesCode
    }

    init(
        expectedTeamIdentifier: String?,
        isDirectRegularFile: @escaping @Sendable (URL) -> Bool = Self.isDirectRegularFile,
        validatesCode: @escaping @Sendable (URL, String) -> Bool = Self.validatesCode
    ) {
        self.expectedTeamIdentifier = expectedTeamIdentifier
        self.isDirectRegularFile = isDirectRegularFile
        self.validatesCode = validatesCode
    }

    /// Returns whether `executable` is a non-symlink signed by the reference app's team.
    /// - Parameter executable: The exact path that will be passed to the process launcher.
    /// - Returns: `true` only when the file and strict code-signature checks both pass.
    public func accepts(_ executable: URL) -> Bool {
        guard isDirectRegularFile(executable), let expectedTeamIdentifier else { return false }
        return validatesCode(executable, expectedTeamIdentifier)
    }

    private static func isDirectRegularFile(_ url: URL) -> Bool {
        var information = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return lstat(path, &information)
        }
        return result == 0 && (information.st_mode & S_IFMT) == S_IFREG
    }

    private static func runningProcessTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
              let information = information as? [String: Any],
              let team = information[kSecCodeInfoTeamIdentifier as String] as? String,
              isRequirementLiteral(team) else { return nil }
        return team
    }

    private static func validatesCode(_ url: URL, team: String) -> Bool {
        guard isRequirementLiteral(team) else { return false }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        return SecStaticCodeCheckValidity(code, strictFlags, requirement) == errSecSuccess
    }

    private static func isRequirementLiteral(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
    }

    private static var strictFlags: SecCSFlags {
        SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
    }
}
