#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
import CmuxNextCompat
import Foundation
import Security

/// The check of a Chromium Host executable's code signature, part of ``ChromiumHostCannotStart``.
nonisolated enum ChromiumHostSignatureCheck: Equatable, Sendable {
    /// Not checked yet.
    case notChecked
    /// The signature on disk is valid.
    case valid
    /// The signature is missing or broken: the `OSStatus` of the check.
    case invalid(OSStatus)

    /// What the cannot-start reason says of it; nil while it is not checked.
    var text: String? {
        switch self {
        case .notChecked: nil
        case .valid: "code signature valid"
        case .invalid(let status): "code signature invalid (OSStatus \(status))"
        }
    }
}

/// Checks a Chromium Host executable's code signature. A blocking call: it reads and hashes the
/// code on disk, so ChromiumHostSession runs it off the main thread (a `@concurrent` function).
nonisolated protocol ChromiumHostSignatureChecking: Sendable {
    func check(_ executable: URL) -> ChromiumHostSignatureCheck
}

/// The check with Security's static code API: the signature of every architecture, strictly.
nonisolated struct SecCodeChromiumHostSignatureChecker: ChromiumHostSignatureChecking {
    func check(_ executable: URL) -> ChromiumHostSignatureCheck {
        var code: SecStaticCode?
        // SAFETY: the call writes one retained SecStaticCode reference into `code`, an optional of that type.
        let created = unsafe SecStaticCodeCreateWithPath(executable as CFURL, [], &code)
        guard created == errSecSuccess, let code else { return .invalid(created) }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        let status = blockingSecStaticCodeCheckValidity(code, flags, nil)
        return status == errSecSuccess ? .valid : .invalid(status)
    }
}
#endif
