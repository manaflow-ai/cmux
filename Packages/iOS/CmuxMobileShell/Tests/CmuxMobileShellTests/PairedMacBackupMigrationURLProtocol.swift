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
    private nonisolated(unsafe) static var uploadStatusCode = 200
    private nonisolated(unsafe) static var didUpload = false
    private nonisolated(unsafe) static var requests: [URLRequest] = []
    private nonisolated(unsafe) static var requestBodies: [Data?] = []

    static func reset(
        primaryScope: String,
        primaryResponse: Data,
        legacyScope: String?,
        legacyResponse: Data,
        primaryResponseAfterUpload: Data? = nil,
        uploadStatusCode: Int = 200
    ) {
        lock.withLock {
            self.primaryScope = primaryScope
            self.primaryResponse = primaryResponse
            self.legacyScope = legacyScope
            self.legacyResponse = legacyResponse
            self.primaryResponseAfterUpload = primaryResponseAfterUpload
            self.uploadStatusCode = uploadStatusCode
            didUpload = false
            requests = []
            requestBodies = []
        }
    }

    static func capturedRequests() -> [URLRequest] {
        lock.withLock { requests }
    }

    static func capturedRequestBodies() -> [Data?] {
        lock.withLock { requestBodies }
    }

    override class func canInit(with _: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let requestBody = request.httpBody
            ?? Self.readBodyStream(request.httpBodyStream)
        let result = Self.lock.withLock { () -> (Data, Int) in
            Self.requests.append(request)
            Self.requestBodies.append(requestBody)
            guard request.httpMethod == "GET" else {
                Self.didUpload = true
                return (
                    Data(#"{"ok":true}"#.utf8),
                    Self.uploadStatusCode
                )
            }
            let scope = request.value(
                forHTTPHeaderField: "X-Cmux-Client-Scope"
            )
            if scope == Self.primaryScope {
                if Self.didUpload,
                   let primaryResponseAfterUpload =
                    Self.primaryResponseAfterUpload {
                    return (primaryResponseAfterUpload, 200)
                }
                return (Self.primaryResponse, 200)
            }
            if scope == Self.legacyScope {
                return (Self.legacyResponse, 200)
            }
            return (
                Data(
                    #"{"records":[],"deletedMacDeviceIDs":[],"revision":0}"#.utf8
                ),
                200
            )
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: result.1,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: result.0)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data.isEmpty ? nil : data
    }
}
