import Foundation
import Security

/// The signing digest changes whenever the helper's signed code or resources change.
nonisolated public struct ComputerUseHelperIdentity: Sendable {
    /// The installed helper bundle whose signature is being checked.
    public let bundleURL: URL

    /// Creates an identity reader for one installed helper bundle.
    public init(bundleURL: URL) {
        self.bundleURL = bundleURL
    }

    /// Returns the code-signing unique digest, or `nil` when it cannot be read.
    public func read() -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &code) == errSecSuccess,
              let code else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
              let values = information as? [String: Any],
              let digest = values[kSecCodeInfoUnique as String] as? Data,
              !digest.isEmpty else { return nil }
        return digest.base64EncodedString()
    }
}
