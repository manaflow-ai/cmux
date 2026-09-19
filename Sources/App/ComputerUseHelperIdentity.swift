import Foundation
import Security

/// The signing digest changes whenever the helper's signed code or resources change.
struct ComputerUseHelperIdentity: Sendable {
    let bundleURL: URL

    func read() -> String? {
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
