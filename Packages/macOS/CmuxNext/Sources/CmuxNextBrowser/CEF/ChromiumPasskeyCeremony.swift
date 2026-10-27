import Foundation

/// `authorizationStateForPlatformCredentials` as the fork's `CMUX_WEBAUTHN_PERMISSION_*`.
nonisolated enum ChromiumPasskeyPermission: Int32, Sendable, Encodable {
    case notDetermined = 0
    case denied = 1
    case authorized = 2
}

/// One iCloud Keychain ceremony cmux runs for a page (a create or a get), with the client data the system
/// must rebuild byte for byte: Chromium gave the page its own client data JSON, so the signature must be
/// over that JSON's hash (``ChromiumPasskeyReply``).
nonisolated struct ChromiumPasskeyCeremony: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case create(user: ChromiumPlatformPasskeyRequest.User, excluded: [Data])
        case get(allowed: [Data], showsHybridTransport: Bool)
    }

    var kind: Kind
    var rpID: String
    var challenge: Data
    var origin: String
    var topOrigin: String?
    /// nil: the client data has no `crossOrigin` member.
    var crossOrigin: Bool?
    var userVerification: String

    init(request: ChromiumPlatformPasskeyRequest, clientData: ChromiumClientData) {
        kind = switch request.operation {
        case .create: .create(user: request.user ?? .init(id: Data(), name: "", displayName: nil), excluded: request.excludeCredentials)
        case .get, .list: .get(allowed: request.allowCredentials, showsHybridTransport: request.showsHybridTransport)
        }
        rpID = request.rpID
        challenge = clientData.challenge
        origin = clientData.origin
        topOrigin = clientData.crossOrigin ? clientData.topOrigin : nil
        crossOrigin = clientData.crossOrigin
        userVerification = request.userVerification
    }
}

/// How a ceremony ended (``ChromiumPlatformPasskeySystem``).
nonisolated enum ChromiumPasskeyCeremonyResult: Sendable, Equatable {
    case registration(credentialID: Data, attestationObject: Data?, clientDataJSON: Data)
    /// `userHandle` is nil when the credential has none (K11: never force-unwrapped).
    case assertion(credentialID: Data, authenticatorData: Data, signature: Data, userHandle: Data?, clientDataJSON: Data)
    /// The ceremony's NSError: Chromium maps it as Chrome does (1001 no credentials, 1006 excluded, others denied).
    case failure(domain: String, code: Int, description: String)
}
