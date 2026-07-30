import Foundation
import Testing
@testable import CmuxMobileShell

@Suite(.serialized)
struct PairedMacBackupMigrationTests {
    @Test func emptyV3CollectionAdoptsOneExplicitLegacyCollection() async throws {
        let record = PairedMacBackupRecord(
            macDeviceID: "legacy-mac",
            displayName: "Legacy Mac",
            routes: [],
            createdAt: 1_000,
            lastSeenAt: 2_000,
            isActive: true
        )
        let legacyResponse = try JSONEncoder().encode(
            TestBackupList(records: [record], deletedMacDeviceIDs: [])
        )
        PairedMacBackupMigrationURLProtocol.reset(
            primaryScope: "ios:v3:Y29tLmNtdXguYXBw",
            primaryResponse: Data(#"{"records":[],"deletedMacDeviceIDs":[]}"#.utf8),
            legacyScope: nil,
            legacyResponse: legacyResponse
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PairedMacBackupMigrationURLProtocol.self]
        let client = PairedMacBackupClient(
            serviceBaseURL: "https://presence.example",
            tokenSource: PresenceTokenSource(
                accessToken: { "access-token" },
                currentUserID: { "user-1" }
            ),
            clientScopeProvider: { "ios:v3:Y29tLmNtdXguYXBw" },
            legacyClientScopeProvider: { nil },
            session: URLSession(configuration: configuration)
        )

        let snapshot = try #require(
            await client.fetchSnapshot(teamID: nil, expectedUserID: "user-1")
        )

        #expect(snapshot.records == [record])
        let requests = PairedMacBackupMigrationURLProtocol.capturedRequests()
        #expect(requests.map(\.httpMethod) == ["GET", "GET", "POST"])
        #expect(requests.map {
            $0.value(forHTTPHeaderField: "X-Cmux-Client-Scope")
        } == [
            "ios:v3:Y29tLmNtdXguYXBw",
            nil,
            "ios:v3:Y29tLmNtdXguYXBw",
        ])
    }
}

private struct TestBackupList: Encodable {
    let records: [PairedMacBackupRecord]
    let deletedMacDeviceIDs: [String]
}

private final class PairedMacBackupMigrationURLProtocol:
    URLProtocol,
    @unchecked Sendable
{
    private static let lock = NSLock()
    private nonisolated(unsafe) static var primaryScope = ""
    private nonisolated(unsafe) static var primaryResponse = Data()
    private nonisolated(unsafe) static var legacyScope: String?
    private nonisolated(unsafe) static var legacyResponse = Data()
    private nonisolated(unsafe) static var requests: [URLRequest] = []

    static func reset(
        primaryScope: String,
        primaryResponse: Data,
        legacyScope: String?,
        legacyResponse: Data
    ) {
        lock.withLock {
            self.primaryScope = primaryScope
            self.primaryResponse = primaryResponse
            self.legacyScope = legacyScope
            self.legacyResponse = legacyResponse
            requests = []
        }
    }

    static func capturedRequests() -> [URLRequest] {
        lock.withLock { requests }
    }

    override class func canInit(with _: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = Self.lock.withLock { () -> Data in
            Self.requests.append(request)
            guard request.httpMethod == "GET" else {
                return Data(#"{"ok":true}"#.utf8)
            }
            let scope = request.value(
                forHTTPHeaderField: "X-Cmux-Client-Scope"
            )
            if scope == Self.primaryScope {
                return Self.primaryResponse
            }
            if scope == Self.legacyScope {
                return Self.legacyResponse
            }
            return Data(#"{"records":[],"deletedMacDeviceIDs":[]}"#.utf8)
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
