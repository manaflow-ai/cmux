import Foundation
import Testing
@testable import CmuxMobileShell

/// The device tree and reconnect path can ask for the same registry snapshot at
/// the same time. The actor must share that in-flight GET instead of multiplying
/// one foreground transition into several auth-provider requests.
@Suite(.serialized)
struct DeviceRegistryRequestDedupTests {
    @Test func overlappingListRequestsShareOneHTTPCall() async {
        RegistryDedupURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RegistryDedupURLProtocol.self]
        let service = DeviceRegistryService(
            apiBaseURL: "https://registry.test",
            deviceID: "ios-device",
            tokenSource: .init(
                accessToken: { "access-token" },
                refreshToken: { "refresh-token" }
            ),
            sessionConfiguration: configuration,
            requestTimeout: 1
        )

        let first = Task { await service.listDevices() }
        for _ in 0..<100 where RegistryDedupURLProtocol.requestCount == 0 {
            await Task.yield()
        }
        let second = Task { await service.listDevices() }
        RegistryDedupURLProtocol.releaseFirstRequest()

        _ = await first.value
        _ = await second.value

        #expect(RegistryDedupURLProtocol.requestCount == 1)
    }

    @Test func changedTeamDoesNotReuseAnOlderInFlightResponse() async {
        RegistryDedupURLProtocol.reset()
        let scope = RegistryDedupTeamScope("team-a")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RegistryDedupURLProtocol.self]
        let service = DeviceRegistryService(
            apiBaseURL: "https://registry.test",
            deviceID: "ios-device",
            tokenSource: .init(
                accessToken: { "access-token" },
                refreshToken: { "refresh-token" }
            ),
            teamIDProvider: { await scope.value },
            sessionConfiguration: configuration,
            requestTimeout: 1
        )

        let first = Task { await service.listDevices() }
        for _ in 0..<10_000 where RegistryDedupURLProtocol.requestCount == 0 {
            await Task.yield()
        }
        #expect(RegistryDedupURLProtocol.requestCount == 1)
        await scope.set("team-b")
        let second = Task { await service.listDevices() }
        for _ in 0..<10_000 where RegistryDedupURLProtocol.requestCount < 2 {
            await Task.yield()
        }
        RegistryDedupURLProtocol.releaseFirstRequest()

        _ = await first.value
        _ = await second.value

        #expect(RegistryDedupURLProtocol.requestCount == 2)
        #expect(Set(RegistryDedupURLProtocol.teamIDs.compactMap { $0 }) == [
            "team-a",
            "team-b",
        ])
    }
}

private actor RegistryDedupTeamScope {
    private(set) var value: String

    init(_ value: String) {
        self.value = value
    }

    func set(_ value: String) {
        self.value = value
    }
}

private final class RegistryDedupURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var count = 0
    private nonisolated(unsafe) static var teams: [String?] = []
    private nonisolated(unsafe) static var blocksFirstRequest = true
    private nonisolated(unsafe) static let firstRequestRelease = DispatchSemaphore(value: 0)

    static var requestCount: Int {
        lock.withLock { count }
    }

    static var teamIDs: [String?] {
        lock.withLock { teams }
    }

    static func reset() {
        lock.withLock {
            count = 0
            teams = []
            blocksFirstRequest = true
        }
    }

    static func releaseFirstRequest() {
        firstRequestRelease.signal()
    }

    override class func canInit(with _: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let shouldBlock = Self.lock.withLock { () -> Bool in
            Self.count += 1
            Self.teams.append(
                request.value(forHTTPHeaderField: "X-Cmux-Team-Id")
            )
            guard Self.blocksFirstRequest else { return false }
            Self.blocksFirstRequest = false
            return true
        }
        if shouldBlock {
            Self.firstRequestRelease.wait()
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["content-type": "application/json"]
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(
            self,
            didLoad: Data(#"{"teamId":"team","devices":[]}"#.utf8)
        )
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
