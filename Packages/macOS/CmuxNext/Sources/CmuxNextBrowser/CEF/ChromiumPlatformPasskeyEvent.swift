import Foundation

/// An iCloud Keychain event of the Chromium Host (WEBAUTHN_PLATFORM_REQUEST and _CANCEL, fork API 31,
/// plans/cmux-next/passkeys.md 3.9). The request JSON holds ceremony secrets (client data, user ids), so
/// neither the description nor the mirror of this value shows it: a log line or a trace of the event
/// carries only the browser, the token and the operation.
nonisolated enum ChromiumPlatformPasskeyEvent: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    /// Chromium asks cmux to run a ceremony for `browser`'s page; answer `token` once.
    case request(browser: Int32, token: Int64, operation: Int32, json: String)
    /// Chromium no longer wants the answer to `token`.
    case cancel(token: Int64)

    var description: String {
        switch self {
        case .request(let browser, let token, let operation, _):
            "webAuthnPlatform.request(browser: \(browser), token: \(token), operation: \(operation))"
        case .cancel(let token):
            "webAuthnPlatform.cancel(token: \(token))"
        }
    }

    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// The fork's `CMUX_WEBAUTHN_PLATFORM_*`.
nonisolated enum ChromiumPlatformPasskeyOperation: Int32, Sendable {
    case create = 0
    case get = 1
    case list = 2
}
