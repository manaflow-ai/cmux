import Foundation
import Testing
@testable import CmuxMobileCloud

@Suite(.serialized)
struct CloudVMServiceTests {
    @Test(arguments: CloudTunnelPurpose.allCases)
    func enrollmentSendsSavedDeviceIDAndRequestedRole(purpose: CloudTunnelPurpose) async throws {
        TeamHeaderURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TeamHeaderURLProtocol.self]
        let service = CloudVMService(
            baseURL: "https://cmux.example",
            tokens: .fixed(accessToken: "access", refreshToken: "refresh", teamID: "team-123"),
            deviceID: { "saved-phone-id" },
            sessionConfiguration: configuration
        )
        let enrollment = try await service.enrollTunnel(
            clientPublicKey: "pub", deviceFingerprint: "role-fingerprint",
            tunnelPurpose: purpose, deviceName: "Phone"
        )
        #expect(enrollment.tunnelId == "tun_1")
        let request = try #require(TeamHeaderURLProtocol.capturedRequest())
        #expect(request.value(forHTTPHeaderField: "X-Cmux-Team-Id") == "team-123")
        let data = try #require(TeamHeaderURLProtocol.capturedBody())
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(body["deviceId"] == "saved-phone-id")
        #expect(body["deviceFingerprint"] == "role-fingerprint")
        #expect(body["tunnelPurpose"] == purpose.rawValue)
        #expect(body["privateKey"] == nil)
    }

    @Test func lockedDeviceIdentityDoesNotSendEnrollment() async {
        TeamHeaderURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TeamHeaderURLProtocol.self]
        let service = CloudVMService(
            baseURL: "https://cmux.example",
            tokens: .fixed(accessToken: "access", refreshToken: "refresh"),
            deviceID: { nil },
            sessionConfiguration: configuration
        )
        await #expect(throws: CloudDeviceIdentityResolver.Failure.storeUnavailable) {
            try await service.enrollTunnel(
                clientPublicKey: "pub", deviceFingerprint: "role-fingerprint",
                tunnelPurpose: .terminal, deviceName: "Phone"
            )
        }
        #expect(TeamHeaderURLProtocol.capturedRequest() == nil)
    }

    @Test func listForwardsSelectedTeamContext() async throws {
        TeamHeaderURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TeamHeaderURLProtocol.self]
        let service = CloudVMService(
            baseURL: "https://cmux.example",
            tokens: .fixed(accessToken: "access", refreshToken: "refresh", teamID: "team-123"),
            deviceID: { "saved-phone-id" },
            sessionConfiguration: configuration
        )

        let machines = try await service.listMachines()

        #expect(machines.isEmpty)
        #expect(TeamHeaderURLProtocol.capturedRequest()?.value(forHTTPHeaderField: "X-Cmux-Team-Id") == "team-123")
    }

    @Test func prefersOneCoherentTokenPair() async throws {
        TeamHeaderURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TeamHeaderURLProtocol.self]
        let service = CloudVMService(
            baseURL: "https://cmux.example",
            tokens: CloudAPITokenSource(
                accessToken: { nil },
                refreshToken: { nil },
                coherentTokenPair: { (accessToken: "coherent-access", refreshToken: "coherent-refresh") }
            ),
            deviceID: { "saved-phone-id" },
            sessionConfiguration: configuration
        )

        _ = try await service.listMachines()

        let request = try #require(TeamHeaderURLProtocol.capturedRequest())
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer coherent-access")
        #expect(request.value(forHTTPHeaderField: "X-Stack-Refresh-Token") == "coherent-refresh")
    }

    @Test func coherentProviderDoesNotFallBackToIndependentReads() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TeamHeaderURLProtocol.self]
        let service = CloudVMService(
            baseURL: "https://cmux.example",
            tokens: CloudAPITokenSource(
                accessToken: { "independent-access" },
                refreshToken: { "independent-refresh" },
                coherentTokenPair: { nil }
            ),
            deviceID: { "saved-phone-id" },
            sessionConfiguration: configuration
        )

        do {
            _ = try await service.listMachines()
            Issue.record("a configured coherent provider must be authoritative")
        } catch let error as CloudAPIError {
            #expect(error == .notSignedIn)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

private final class TeamHeaderURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var request: URLRequest?
    private nonisolated(unsafe) static var body: Data?

    static func reset() {
        lock.withLock { request = nil; body = nil }
    }

    static func capturedRequest() -> URLRequest? {
        lock.withLock { request }
    }

    static func capturedBody() -> Data? { lock.withLock { body } }

    override class func canInit(with _: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        var requestBody = request.httpBody
        if requestBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            requestBody = data
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.withLock { Self.request = request; Self.body = requestBody }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let payload = url.path == "/api/vm/tunnel" ? Fixtures.enrollmentJSON : #"{"vms":[]}"#
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
