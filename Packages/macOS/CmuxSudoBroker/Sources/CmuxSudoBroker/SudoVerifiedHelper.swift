import Foundation

/// A bundled helper whose expected content was authenticated by the app's resource seal.
struct SudoVerifiedHelper: Sendable, Equatable {
    /// The user-writable bundle path the root side copies from.
    let sourceURL: URL
    /// The lowercase hex SHA-256 the staged copy must match.
    let sha256: String
    /// The requirement the staged copy must satisfy, for signed Mach-O helpers.
    let requirement: SudoCodeSigningRequirement?
    /// The fixed interpreter for script helpers.
    let interpreter: String?
}

protocol SudoBundledHelperResolving: Sendable {
    func privilegedExecutor() throws -> SudoVerifiedHelper
    func touchIDSetupScript() throws -> SudoVerifiedHelper
}

/// Resolves bundled helpers only after the enclosing app bundle passes signature validation.
struct SudoBundledHelperResolver: SudoBundledHelperResolving {
    static let executorResourcePath = "Resources/bin/cmux"
    static let touchIDSetupResourcePath = "Resources/bin/setup-pam-tid.sh"
    static let touchIDSetupInterpreter = "/bin/bash"

    let policy: SudoBundledHelperPolicy
    let checker: any SudoCodeSignatureChecking

    init(
        policy: SudoBundledHelperPolicy,
        checker: any SudoCodeSignatureChecking = SystemSudoCodeSignatureChecker()
    ) {
        self.policy = policy
        self.checker = checker
    }

    func privilegedExecutor() throws -> SudoVerifiedHelper {
        try resolve(
            resourcePath: Self.executorResourcePath,
            requirement: policy.executorRequirement,
            interpreter: nil
        )
    }

    func touchIDSetupScript() throws -> SudoVerifiedHelper {
        try resolve(
            resourcePath: Self.touchIDSetupResourcePath,
            requirement: nil,
            interpreter: Self.touchIDSetupInterpreter
        )
    }

    private func resolve(
        resourcePath: String,
        requirement: SudoCodeSigningRequirement?,
        interpreter: String?
    ) throws -> SudoVerifiedHelper {
        let digest = try checker.sealedResourceDigest(
            bundleURL: policy.appBundleURL,
            requirement: policy.bundleRequirement,
            resourcePath: resourcePath
        )
        guard digest.count == 32 else { throw SudoCodeSignatureError.resourceNotSealed }
        return SudoVerifiedHelper(
            sourceURL: policy.appBundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent(resourcePath, isDirectory: false),
            sha256: SudoSHA256.hex(digest: digest),
            requirement: requirement,
            interpreter: interpreter
        )
    }
}

/// Fails closed when no signing policy was supplied.
struct SudoUnavailableHelperResolver: SudoBundledHelperResolving {
    func privilegedExecutor() throws -> SudoVerifiedHelper {
        throw SudoCodeSignatureError.invalidPolicy
    }

    func touchIDSetupScript() throws -> SudoVerifiedHelper {
        throw SudoCodeSignatureError.invalidPolicy
    }
}
