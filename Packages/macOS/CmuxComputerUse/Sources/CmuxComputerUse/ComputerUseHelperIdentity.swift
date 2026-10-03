import CryptoKit
import Foundation
import Security

/// The signing digest changes whenever the helper's signed code or resources change.
public struct ComputerUseHelperIdentity: Sendable {
    /// The installed helper bundle whose signature is being checked.
    public let bundleURL: URL

    /// Creates an identity reader for one installed helper bundle.
    public init(bundleURL: URL) {
        self.bundleURL = bundleURL
    }

    /// Returns the code-signing unique digest, or a content identity for an
    /// ad-hoc build when its signing metadata is unavailable.
    public func read() -> String? {
        var code: SecStaticCode?
        if SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &code) == errSecSuccess,
           let code {
            var information: CFDictionary?
            if SecCodeCopySigningInformation(
                code,
                SecCSFlags(rawValue: kSecCSSigningInformation),
                &information
            ) == errSecSuccess,
               let values = information as? [String: Any],
               let digest = values[kSecCodeInfoUnique as String] as? Data,
               !digest.isEmpty {
                return digest.base64EncodedString()
            }
        }

        // Ad-hoc development builds can have no readable code-signing
        // identity. Keep recovery scoped to the exact installed helper by
        // deriving a stable identity from its executable.
        guard let executableURL = Bundle(url: bundleURL)?.executableURL,
              let executable = try? Data(contentsOf: executableURL, options: .mappedIfSafe),
              !executable.isEmpty else { return nil }
        return Self.fallbackIdentity(forExecutable: executable)
    }

    static func fallbackIdentity(forExecutable executable: Data) -> String {
        "content:" + SHA256.hash(data: executable)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
