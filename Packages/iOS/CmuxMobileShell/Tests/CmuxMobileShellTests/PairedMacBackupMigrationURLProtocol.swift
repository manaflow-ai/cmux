import Foundation

final class PairedMacBackupMigrationURLProtocol:
    URLProtocol,
    @unchecked Sendable
{
    private static let lock = NSLock()
    private nonisolated(unsafe) static var primaryScope = ""
    private nonisolated(unsafe) static var primaryResponse = Data()
    private nonisolated(unsafe) static var legacyScope: String?
    private nonisolated(unsafe) static var legacyResponse = Data()
    private nonisolated(unsafe) static var primaryResponseAfterUpload: Data?
    private nonisolated(unsafe) static var didUpload = false
    private nonisolated(unsafe) static var requests: [URLRequest] = []

    static func reset(
        primaryScope: String,
        primaryResponse: Data,
        legacyScope: String?,
        legacyResponse: Data,
        primaryResponseAfterUpload: Data? = nil
    ) {
        lock.withLock {
            self.primaryScope = primaryScope
            self.primaryResponse = primaryResponse
            self.legacyScope = legacyScope
            self.legacyResponse = legacyResponse
            self.primaryResponseAfterUpload = primaryResponseAfterUpload
            didUpload = false
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
                Self.didUpload = true
                return Data(#"{"ok":true}"#.utf8)
            }
            let scope = request.value(
                forHTTPHeaderField: "X-Cmux-Client-Scope"
            )
            if scope == Self.primaryScope {
                if Self.didUpload,
                   let primaryResponseAfterUpload =
                    Self.primaryResponseAfterUpload {
                    return primaryResponseAfterUpload
                }
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
