public import Foundation
import CMUXMobileCore

/// The live `/api/vm` client over a redirect-refusing, cookie-free session.
public actor CloudVMService: CloudVMServing {
    private let requests: CloudAPIRequestBuilder
    private let decoding = CloudAPIResponseDecoding()
    private let tokens: CloudAPITokenSource
    private let session: CmxCredentialedHTTPSession

    /// Creates the service.
    /// - Parameters:
    ///   - baseURL: The cmux web API origin.
    ///   - tokens: Live Stack token source.
    ///   - sessionConfiguration: URL loading configuration; cookies and caches
    ///     are disabled by the credentialed session regardless.
    public init(
        baseURL: String,
        tokens: CloudAPITokenSource,
        sessionConfiguration: sending URLSessionConfiguration = .ephemeral
    ) {
        self.requests = CloudAPIRequestBuilder(baseURL: baseURL)
        self.tokens = tokens
        self.session = CmxCredentialedHTTPSession(configuration: sessionConfiguration)
    }

    public func listMachines() async throws -> [CloudMachine] {
        let (access, refresh) = try await credentials()
        let data = try await send(requests.listMachines(accessToken: access, refreshToken: refresh))
        return try decoding.machines(from: data)
    }

    public func enrollTunnel(
        clientPublicKey: String,
        deviceFingerprint: String,
        deviceName: String?
    ) async throws -> CloudTunnelEnrollment {
        let (access, refresh) = try await credentials()
        let data = try await send(requests.enrollTunnel(
            clientPublicKey: clientPublicKey,
            deviceFingerprint: deviceFingerprint,
            deviceName: deviceName,
            accessToken: access,
            refreshToken: refresh
        ))
        return try decoding.tunnelEnrollment(from: data)
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
        guard let access = await tokens.accessToken(), !access.isEmpty,
              let refresh = await tokens.refreshToken(), !refresh.isEmpty else {
            throw CloudAPIError.notSignedIn
        }
        return (access, refresh)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudAPIError.malformedResponse("non-HTTP response")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw CloudAPIError.httpStatus(http.statusCode, message: decoding.errorMessage(from: data))
        }
        return data
    }
}
