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
        let credentials = try await credentials()
        let data = try await send(
            requests.listMachines(
                accessToken: credentials.accessToken,
                refreshToken: credentials.refreshToken
            ),
            teamID: credentials.teamID
        )
        return try decoding.catalog(from: data)
    }

    public func createMachine(options: CloudMachineCreateOptions, idempotencyKey: String) async throws -> CloudMachine {
        let credentials = try await credentials()
        let data = try await send(requests.createMachine(
            options: options,
            idempotencyKey: idempotencyKey,
            accessToken: credentials.accessToken,
            refreshToken: credentials.refreshToken
        ), teamID: credentials.teamID)
        return try decoding.createdMachine(from: data)
    }

    public func enrollTunnel(
        clientPublicKey: String,
        deviceFingerprint: String,
        tunnelPurpose: CloudTunnelPurpose,
        deviceName: String?
    ) async throws -> CloudTunnelEnrollment {
        let credentials = try await credentials()
        return try await enrollTunnel(
            clientPublicKey: clientPublicKey,
            deviceFingerprint: deviceFingerprint,
            tunnelPurpose: tunnelPurpose,
            deviceName: deviceName,
            accessToken: credentials.accessToken,
            refreshToken: credentials.refreshToken,
            teamID: credentials.teamID
        )
    }

    /// Enrolls a browser peer using the token context captured when the
    /// operation started.
    public func enrollTunnel(
        clientPublicKey: String,
        deviceFingerprint: String,
        tunnelPurpose: CloudTunnelPurpose,
        deviceName: String?,
        credentials: CloudAPITokenSource.TokenContext?
    ) async throws -> CloudTunnelEnrollment {
        guard let credentials else {
            throw CloudAPIError.notSignedIn
        }
        return try await enrollTunnel(
            clientPublicKey: clientPublicKey,
            deviceFingerprint: deviceFingerprint,
            tunnelPurpose: tunnelPurpose,
            deviceName: deviceName,
            accessToken: credentials.accessToken,
            refreshToken: credentials.refreshToken,
            teamID: credentials.teamID
        )
    }

    private func enrollTunnel(
        clientPublicKey: String,
        deviceFingerprint: String,
        tunnelPurpose: CloudTunnelPurpose,
        deviceName: String?,
        accessToken: String,
        refreshToken: String,
        teamID: String?
    ) async throws -> CloudTunnelEnrollment {
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
            accessToken: accessToken,
            refreshToken: refreshToken
        ), teamID: teamID)
        let enrollment = try decoding.tunnelEnrollment(from: data)
        log.info("Cloud enrollment succeeded purpose=\(tunnelPurpose.rawValue, privacy: .public)")
        return enrollment
    }

    /// Revokes one role with the currently signed-in credentials.
    public func revokeTunnel(deviceFingerprint: String, tunnelPurpose: CloudTunnelPurpose) async throws {
        let credentials = try await credentials()
        try await revokeTunnel(
            deviceFingerprint: deviceFingerprint,
            tunnelPurpose: tunnelPurpose,
            accessToken: credentials.accessToken,
            refreshToken: credentials.refreshToken,
            teamID: credentials.teamID
        )
    }

    /// Revokes one role with a token pair captured before local sign-out.
    public func revokeTunnel(
        deviceFingerprint: String,
        tunnelPurpose: CloudTunnelPurpose,
        accessToken: String,
        refreshToken: String
    ) async throws {
        try await revokeTunnel(
            deviceFingerprint: deviceFingerprint,
            tunnelPurpose: tunnelPurpose,
            accessToken: accessToken,
            refreshToken: refreshToken,
            teamID: nil
        )
    }

    /// Revokes one role with tokens and the team captured before sign-out.
    public func revokeTunnel(
        deviceFingerprint: String,
        tunnelPurpose: CloudTunnelPurpose,
        accessToken: String,
        refreshToken: String,
        teamID: String?
    ) async throws {
        let request = try requests.revokeTunnel(
            deviceFingerprint: deviceFingerprint,
            tunnelPurpose: tunnelPurpose,
            accessToken: accessToken,
            refreshToken: refreshToken
        )
        _ = try await send(request, teamID: teamID)
    }

    public func openAttach(machineID: String, deviceFingerprint: String) async throws -> CloudAttachEndpoint {
        let credentials = try await credentials()
        let data = try await send(requests.openAttach(
            machineID: machineID,
            deviceFingerprint: deviceFingerprint,
            clientCapabilities: [],
            accessToken: credentials.accessToken,
            refreshToken: credentials.refreshToken
        ), teamID: credentials.teamID)
        return try decoding.attachEndpoint(from: data)
    }

    public func approveEnrollment(machineID: String, invitationId: String) async throws -> Bool {
        let credentials = try await credentials()
        let data = try await send(requests.approveEnrollment(
            machineID: machineID,
            invitationId: invitationId,
            accessToken: credentials.accessToken,
            refreshToken: credentials.refreshToken
        ), teamID: credentials.teamID)
        return try decoding.approvalGranted(from: data)
    }

    private func credentials() async throws -> CloudAPITokenSource.TokenContext {
        let context: CloudAPITokenSource.TokenContext?
        do {
            context = try await tokens.coherentTokenContext()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CloudAPIError.sessionUnavailable
        }
        guard let context,
              !context.accessToken.isEmpty,
              !context.refreshToken.isEmpty else {
            throw CloudAPIError.notSignedIn
        }
        return context
    }

    public func pauseMachine(id: String) async throws {
        let credentials = try await credentials()
        _ = try await send(
            requests.pauseMachine(
                id: id,
                accessToken: credentials.accessToken,
                refreshToken: credentials.refreshToken
            ),
            teamID: credentials.teamID
        )
    }

    public func resumeMachine(id: String) async throws {
        let credentials = try await credentials()
        _ = try await send(
            requests.resumeMachine(
                id: id,
                accessToken: credentials.accessToken,
                refreshToken: credentials.refreshToken
            ),
            teamID: credentials.teamID
        )
    }

    public func deleteMachine(id: String) async throws {
        let credentials = try await credentials()
        _ = try await send(
            requests.deleteMachine(
                id: id,
                accessToken: credentials.accessToken,
                refreshToken: credentials.refreshToken
            ),
            teamID: credentials.teamID
        )
    }

    private func send(
        _ request: URLRequest,
        teamID: String? = nil
    ) async throws -> Data {
        var request = request
        if let teamID, !teamID.isEmpty {
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
