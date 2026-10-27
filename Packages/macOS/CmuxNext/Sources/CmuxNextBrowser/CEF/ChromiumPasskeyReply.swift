import Foundation

/// One iCloud Keychain passkey of an rp id the person may pick (`platformCredentialsForRelyingParty`).
nonisolated struct ChromiumPlatformCredential: Sendable, Equatable {
    var credentialID: Data
    var userHandle: Data
    var name: String
    var providerName: String
}

/// The reply JSON of include/cef_cmux.h (`cmux_webauthn_platform_reply`). Byte strings are unpadded base64url.
/// It holds ceremony secrets (signatures): built here, handed to the shim, never logged.
nonisolated enum ChromiumPasskeyReply {
    private struct Failed: Encodable {
        struct Detail: Encodable {
            var domain: String
            var code: Int
            var description: String
        }

        var error: Detail
        var permission: ChromiumPasskeyPermission
    }

    private struct Created: Encodable {
        var attestationObject: String
        var credentialID: String
        var permission: ChromiumPasskeyPermission

        enum CodingKeys: String, CodingKey {
            case attestationObject = "attestation_object", credentialID = "credential_id", permission
        }
    }

    private struct Asserted: Encodable {
        var authenticatorData: String
        var signature: String
        var userHandle: String?
        var credentialID: String
        var permission: ChromiumPasskeyPermission

        enum CodingKeys: String, CodingKey {
            case authenticatorData = "authenticator_data", signature, userHandle = "user_handle", credentialID = "credential_id"
            case permission
        }
    }

    private struct Listed: Encodable {
        struct Credential: Encodable {
            var credentialID: String
            var userHandle: String
            var name: String
            var providerName: String

            enum CodingKeys: String, CodingKey {
                case credentialID = "credential_id", userHandle = "user_handle", name, providerName = "provider_name"
            }
        }

        var credentials: [Credential]
        var permission: ChromiumPasskeyPermission
    }

    /// The reply to a create or get; nil (Chromium answers NotAllowedError) when the system's client data
    /// is not Chromium's, since the page would then hold a signature over other bytes, or when a
    /// registration has no attestation object.
    static func json(for result: ChromiumPasskeyCeremonyResult, chromiumClientData: Data,
                     permission: ChromiumPasskeyPermission) -> String? {
        let text = ChromiumPlatformPasskeyRequest.text
        switch result {
        case .failure(let domain, let code, let description):
            return encode(Failed(error: .init(domain: domain, code: code, description: description), permission: permission))
        case .registration(let credentialID, let attestationObject, let clientDataJSON):
            guard clientDataJSON == chromiumClientData, let attestationObject else { return nil }
            return encode(Created(attestationObject: text(attestationObject), credentialID: text(credentialID), permission: permission))
        case .assertion(let credentialID, let authenticatorData, let signature, let userHandle, let clientDataJSON):
            guard clientDataJSON == chromiumClientData else { return nil }
            return encode(Asserted(authenticatorData: text(authenticatorData), signature: text(signature),
                                   userHandle: userHandle.map(text), credentialID: text(credentialID), permission: permission))
        }
    }

    /// The reply to a list.
    static func json(listing credentials: [ChromiumPlatformCredential], permission: ChromiumPasskeyPermission) -> String? {
        let text = ChromiumPlatformPasskeyRequest.text
        let rows = credentials.map {
            Listed.Credential(credentialID: text($0.credentialID), userHandle: text($0.userHandle), name: $0.name,
                              providerName: $0.providerName)
        }
        return encode(Listed(credentials: rows, permission: permission))
    }

    private static func encode(_ value: some Encodable) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) }
    }
}
