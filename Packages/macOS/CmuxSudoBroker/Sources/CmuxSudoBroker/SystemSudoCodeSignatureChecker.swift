import Foundation
import Security

/// Validates the enclosing app bundle with Security.framework static-code checks.
struct SystemSudoCodeSignatureChecker: SudoCodeSignatureChecking {
    /// The signing-information key that carries the validated `CodeResources` dictionary.
    private static let resourceDirectoryKey = "ResourceDirectory"

    func sealedResourceDigest(
        bundleURL: URL,
        requirement: SudoCodeSigningRequirement?,
        resourcePath: String
    ) throws -> Data {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            bundleURL.standardizedFileURL as CFURL,
            [],
            &staticCode
        )
        guard createStatus == errSecSuccess, let staticCode else {
            throw SudoCodeSignatureError.staticCode(createStatus)
        }

        var compiledRequirement: SecRequirement?
        if let requirement {
            let status = SecRequirementCreateWithString(
                requirement.text as CFString,
                [],
                &compiledRequirement
            )
            guard status == errSecSuccess, compiledRequirement != nil else {
                throw SudoCodeSignatureError.requirement(status)
            }
        }

        // Full validation authenticates every sealed resource and the CodeResources
        // dictionary itself against the code directory before its digests are read.
        let validationFlags = SecCSFlags(
            rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures
        )
        var validationError: Unmanaged<CFError>?
        let validityStatus = SecStaticCodeCheckValidityWithErrors(
            staticCode,
            validationFlags,
            compiledRequirement,
            &validationError
        )
        validationError?.release()
        guard validityStatus == errSecSuccess else {
            throw SudoCodeSignatureError.invalidSignature(validityStatus)
        }

        // The resource seal is only reported with internal information. It comes from the
        // same static-code object, so it is the dictionary the validity check authenticated.
        var information: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSInternalInformation),
            &information
        )
        guard informationStatus == errSecSuccess,
              let information = information as? [String: Any],
              let resourceDirectory = information[Self.resourceDirectoryKey] as? [String: Any],
              let files = resourceDirectory["files2"] as? [String: Any],
              let entry = files[resourcePath] as? [String: Any],
              entry["symlink"] == nil,
              entry["cdhash"] == nil,
              let digest = entry["hash2"] as? Data,
              digest.count == 32 else {
            throw informationStatus == errSecSuccess
                ? SudoCodeSignatureError.resourceNotSealed
                : SudoCodeSignatureError.signingInformation(informationStatus)
        }
        return digest
    }
}

/// Reads the running process's own signature for debug-scoped helper pinning.
struct SystemSudoRunningCodeIdentityReader: SudoRunningCodeIdentityReading {
    func designatedRequirement() throws -> SudoCodeSigningRequirement {
        let staticCode = try selfStaticCode()
        var requirement: SecRequirement?
        let status = SecCodeCopyDesignatedRequirement(staticCode, [], &requirement)
        guard status == errSecSuccess, let requirement else {
            throw SudoCodeSignatureError.runningCode(status)
        }
        var text: CFString?
        let textStatus = SecRequirementCopyString(requirement, [], &text)
        guard textStatus == errSecSuccess, let text else {
            throw SudoCodeSignatureError.runningCode(textStatus)
        }
        return SudoCodeSigningRequirement(text: text as String)
    }

    func teamIdentifier() -> String? {
        guard let staticCode = try? selfStaticCode() else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
            let information = information as? [String: Any] else {
            return nil
        }
        return information[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private func selfStaticCode() throws -> SecStaticCode {
        var code: SecCode?
        let status = SecCodeCopySelf([], &code)
        guard status == errSecSuccess, let code else {
            throw SudoCodeSignatureError.runningCode(status)
        }
        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(code, [], &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else {
            throw SudoCodeSignatureError.runningCode(staticStatus)
        }
        // A running process whose own signature is broken cannot vouch for anything.
        let validity = SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            nil
        )
        guard validity == errSecSuccess else {
            throw SudoCodeSignatureError.runningCode(validity)
        }
        return staticCode
    }
}
