public import Foundation
import CMUXMobileCore
import OSLog

/// The live `/api/vm` client over a redirect-refusing, cookie-free session.
public actor CloudVMService: CloudVMServing {
    private let requests: CloudAPIRequestBuilder
    private let decoding = CloudAPIResponseDecoding()
    private let tokens: CloudAPITokenSource
    private let session: CmxCredentialedHTTPSession
    private let deviceID: @Sendable () async -> String?
    private let log = Logger(subsystem: "dev.cmux.ios", category: "cloud-api")

    /// Creates the service.
    /// - Parameters:
    ///   - baseURL: The cmux web API origin.
    ///   - tokens: Live Stack token source.
    ///   - deviceID: Durable device-registry ID shared by both tunnel roles.
    ///   - sessionConfiguration: URL loading configuration; cookies and caches
    ///     are disabled by the credentialed session regardless.
    public init(
        baseURL: String,
        tokens: CloudAPITokenSource,
        deviceID: @escaping @Sendable () async -> String?,
        sessionConfiguration: sending URLSessionConfiguration = .ephemeral
    ) {
        self.requests = CloudAPIRequestBuilder(baseURL: baseURL)
        self.tokens = tokens
        self.deviceID = deviceID
        self.session = CmxCredentialedHTTPSession(configuration: sessionConfiguration)
    }

    public func listMachines() async throws -> [CloudMachine] {
        try await listMachineCatalog().machines
    }

    public func listMachineCatalog() async throws -> CloudMachineCatalog {
        let (access, refresh) = try await credentials()
        let data = try await send(requests.listMachines(accessToken: access, refreshToken: refresh))
        return try decoding.catalog(from: data)
    }

    public func createMachine(options: CloudMachineCreateOptions, idempotencyKey: String) async throws -> CloudMachine {
        let (access, refresh) = try await credentials()
        let data = try await send(requests.createMachine(
            options: options,
            idempotencyKey: idempotencyKey,
            accessToken: access,
            refreshToken: refresh
        ))
        return try decoding.createdMachine(from: data)
    }

    public func enrollTunnel(
        clientPublicKey: String,
        deviceFingerprint: String,
        tunnelPurpose: CloudTunnelPurpose,
        deviceName: String?
    ) async throws -> CloudTunnelEnrollment {
        let (access, refresh) = try await credentials()
        guard let deviceID = await deviceID()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !deviceID.isEmpty else {
            throw CloudDeviceIdentityResolver.Failure.storeUnavailable
        }
        log.info("Cloud enrollment started purpose=\(tunnelPurpose.rawValue, privacy: .public)")
        let data = try await send(requests.enrollTunnel(
            clientPublicKey: clientPublicKey,
            deviceID: deviceID,
            deviceFingerprint: deviceFingerprint,
            tunnelPurpose: tunnelPurpose,
            deviceName: deviceName,
            accessToken: access,
            refreshToken: refresh
        ))
        let enrollment = try decoding.tunnelEnrollment(from: data)
        log.info("Cloud enrollment succeeded purpose=\(tunnelPurpose.rawValue, privacy: .public)")
        return enrollment
    }

    public func openAttach(machineID: String, deviceFingerprint: String) async throws -> CloudAttachEndpoint {
        let (access, refresh) = try await credentials()
        let data = try await send(requests.openAttach(
            machineID: machineID,
            deviceFingerprint: deviceFingerprint,
            clientCapabilities: [],
            accessToken: access,
            refreshToken: refresh
        ))
        return try decoding.attachEndpoint(from: data)
    }

    public func approveEnrollment(machineID: String, invitationId: String) async throws -> Bool {
        let (access, refresh) = try await credentials()
        let data = try await send(requests.approveEnrollment(
            machineID: machineID,
            invitationId: invitationId,
            accessToken: access,
            refreshToken: refresh
        ))
        return try decoding.approvalGranted(from: data)
    }

    private func credentials() async throws -> (String, String) {
        if let coherentTokenPair = tokens.coherentTokenPair {
            guard let pair = await coherentTokenPair(),
                  !pair.accessToken.isEmpty,
                  !pair.refreshToken.isEmpty else {
                throw CloudAPIError.notSignedIn
            }
            return pair
        }
        guard let access = await tokens.accessToken(), !access.isEmpty,
              let refresh = await tokens.refreshToken(), !refresh.isEmpty else {
            throw CloudAPIError.notSignedIn
        }
        return (access, refresh)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        var request = request
        if let teamID = await tokens.teamID(), !teamID.isEmpty {
            request.setValue(teamID, forHTTPHeaderField: "X-Cmux-Team-Id")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudAPIError.malformedResponse("non-HTTP response")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            log.error("Cloud request rejected status=\(http.statusCode, privacy: .public) path=\(request.url?.path ?? "", privacy: .private)")
            let envelope = decoding.errorEnvelope(from: data)
            throw CloudAPIError.httpStatus(http.statusCode, message: envelope.message, action: envelope.action)
        }
        return data
    }
}
