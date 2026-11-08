public import CMUXMobileCore
import Foundation

/// Values needed by Hooke's existing key/pin store after the authenticated RPC.
public struct MobilePhonePushKeyExchangeContext: Sendable {
    public let accountID: String
    public let teamID: String?
    public let clientID: String
    public let iosBuildID: String
    public let iosInstallationID: String
    public let macDeviceID: String
    public let macInstanceTag: String
    public let macBuildID: String

    public init(
        accountID: String,
        teamID: String?,
        clientID: String,
        iosBuildID: String,
        iosInstallationID: String,
        macDeviceID: String,
        macInstanceTag: String,
        macBuildID: String
    ) {
        self.accountID = accountID
        self.teamID = teamID
        self.clientID = clientID
        self.iosBuildID = iosBuildID
        self.iosInstallationID = iosInstallationID
        self.macDeviceID = macDeviceID
        self.macInstanceTag = macInstanceTag
        self.macBuildID = macBuildID
    }
}

/// Shell-to-push injection boundary. Hooke supplies the descriptor and pins
/// the returned Mac descriptor in the shared PhonePushPeerKeyStore.
public struct MobilePhonePushKeyExchangeHooks: Sendable {
    public let makeDescriptor: @Sendable () throws -> MobilePhonePushPublicKeyDescriptor
    public let iosBuildID: @Sendable () -> String
    public let pinPeerDescriptor: @MainActor @Sendable (
        MobilePhonePushPublicKeyDescriptor,
        MobilePhonePushKeyExchangeContext
    ) async -> Void

    public init(
        makeDescriptor: @escaping @Sendable () throws -> MobilePhonePushPublicKeyDescriptor,
        iosBuildID: @escaping @Sendable () -> String,
        pinPeerDescriptor: @escaping @MainActor @Sendable (
            MobilePhonePushPublicKeyDescriptor,
            MobilePhonePushKeyExchangeContext
        ) async -> Void
    ) {
        self.makeDescriptor = makeDescriptor
        self.iosBuildID = iosBuildID
        self.pinPeerDescriptor = pinPeerDescriptor
    }
}

public extension MobileCoreRPCClient {
    /// Exchanges peer push descriptors over the already authenticated RPC
    /// connection. Keys never come from the backend or relay directory.
    func exchangePhonePushKey(
        hooks: MobilePhonePushKeyExchangeHooks,
        clientID: String
    ) async throws -> (
        response: MobilePhonePushKeyExchangeResponse,
        request: MobilePhonePushKeyExchangeRequest
    ) {
        let descriptor = try hooks.makeDescriptor()
        let request = MobilePhonePushKeyExchangeRequest(
            clientID: clientID,
            iosBuildID: hooks.iosBuildID(),
            descriptor: descriptor
        )
        try request.validate()
        let requestData = try Self.requestData(
            method: "phone_push.keys.exchange",
            params: try Self.jsonObject(request)
        )
        let responseData = try await sendRequest(
            requestData,
            timeoutNanoseconds: 3_000_000_000
        )
        let response = try JSONDecoder().decode(
            MobilePhonePushKeyExchangeResponse.self,
            from: responseData
        )
        try response.validate()
        return (response, request)
    }
}

private extension MobileCoreRPCClient {
    static func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MobilePhonePushKeyExchangeError.invalidRequest
        }
        return object
    }
}
