public import CmuxInstallAuthCore
public import CmuxLinkWebRTC
public import CmuxPairing
public import Foundation

/// `MobileLinkHostAccount` for the signed-in Mac (d1-terminal-ux.md 7): the
/// backend install principal (`InstallAuthClient`, registered as a `mac`
/// install with the account's Stack session, tokens from a signed challenge),
/// the host it enrolled (`host.enroll`), and the install key as the link
/// signers. One instance per signed-in Stack user; the app makes a new one on
/// an account switch.
public actor InstallHostAccount: MobileLinkHostAccount {
    private let client: InstallAuthClient
    private let enrollment: HostEnrollment
    private let apiBaseURL: URL
    private let macName: @Sendable () async -> String
    private let current: @Sendable () async -> Bool
    private var principalCache: MobileLinkHostPrincipal?

    public nonisolated let installSigner: (any LinkKeySigning)?
    public nonisolated let webrtcIdentity: (any WebRTCIdentity)?

    /// - Parameters:
    ///   - apiBaseURL: the API Worker origin (`/v1/ops`, `/v1/auth/*`, `/v1/wire/*`).
    ///   - stackUser: the signed-in Stack user id; `user.ensure` must agree.
    ///   - sessionToken: the Stack access token, needed only to register.
    ///   - deviceName: the install's device name (the Mac's computer name at registration).
    ///   - macName: the host's display name, read at enrollment.
    ///   - isCurrent: false once the user signed out or switched account.
    public init(apiBaseURL: URL, stackUser: String, sessionToken: @escaping InstallAuthClient.SessionToken,
                deviceName: String, clientVersion: String?, key: MacInstallKey, records: MacInstallRecordStore,
                transport: (any InstallAuthTransport)? = nil,
                macName: @escaping @Sendable () async -> String,
                isCurrent: @escaping @Sendable () async -> Bool) {
        let transport = transport ?? URLSessionInstallAuthTransport(baseURL: apiBaseURL)
        self.apiBaseURL = apiBaseURL
        self.macName = macName
        current = isCurrent
        enrollment = HostEnrollment(transport: transport, clientVersion: clientVersion)
        client = InstallAuthClient(transport: transport, signer: key, sessionToken: sessionToken, stackUser: stackUser,
                                   deviceName: deviceName, clientVersion: clientVersion, record: records.record(for: stackUser),
                                   profile: .mac, onRecord: { records.setRecord($0, for: stackUser) })
        installSigner = key
        webrtcIdentity = try? MacInstallKeyIdentity(key: key)
    }

    public func principal() async throws -> MobileLinkHostPrincipal {
        if let principalCache { return principalCache }
        let token = try await client.installToken()
        guard let record = await client.currentRecord, let environment = await client.environment else {
            throw InstallAuthError.noSession
        }
        let host = try await enrollment.enroll(install: record.install, name: await macName(), token: token)
        let made = MobileLinkHostPrincipal(hostID: host, accountUserID: record.user, install: record.install,
                                           environment: environment, apiBaseURL: apiBaseURL)
        principalCache = made
        return made
    }

    public func installToken() async throws -> String {
        try await client.installToken()
    }

    public func isCurrent() async -> Bool {
        await current()
    }
}
