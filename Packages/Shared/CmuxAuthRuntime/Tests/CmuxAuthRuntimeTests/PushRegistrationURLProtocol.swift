import Foundation

private struct PushRegistrationLoadingContext: @unchecked Sendable {
    let loadingProtocol: PushRegistrationURLProtocol
}

/// Scripted transport for push-registration lifecycle tests.
///
/// `URLProtocol` is configured by type, so one actor-backed script is shared by
/// this serialized suite. The actor owns both the response queue and request
/// capture, keeping test mutation out of process-global unsafe variables.
final class PushRegistrationURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        let statusCode: Int?
        let headers: [String: String]
        let body: Data
        let error: URLError?
        let started: TestPhaseSignal?
        let blocker: TestContinuationBlocker?

        static func response(
            _ statusCode: Int,
            headers: [String: String] = [:],
            json: String = #"{"ok":true}"#
        ) -> Stub {
            Stub(
                statusCode: statusCode,
                headers: headers,
                body: Data(json.utf8),
                error: nil,
                started: nil,
                blocker: nil
            )
        }

        static func gatedResponse(
            _ statusCode: Int,
            started: TestPhaseSignal,
            blocker: TestContinuationBlocker,
            headers: [String: String] = [:],
            json: String = #"{"ok":true}"#
        ) -> Stub {
            Stub(
                statusCode: statusCode,
                headers: headers,
                body: Data(json.utf8),
                error: nil,
                started: started,
                blocker: blocker
            )
        }

        static func failure(_ code: URLError.Code) -> Stub {
            Stub(
                statusCode: nil,
                headers: [:],
                body: Data(),
                error: URLError(code),
                started: nil,
                blocker: nil
            )
        }
    }

    static let script = PushRegistrationURLScript()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let capturedRequest = request
        let capturedBody = Self.bodyData(from: capturedRequest)
        let stub = Self.script.take(capturedRequest, body: capturedBody)
        let context = PushRegistrationLoadingContext(
            loadingProtocol: self
        )
        if stub.error != nil {
            Task.detached { [capturedRequest, context] in
                await Task.yield()
                context.complete(stub, request: capturedRequest)
            }
            return
        }
        guard stub.started != nil || stub.blocker != nil else {
            context.complete(stub, request: capturedRequest)
            return
        }
        Task.detached { [capturedRequest, context] in
            await stub.started?.markStarted()
            await stub.blocker?.wait()
            context.complete(stub, request: capturedRequest)
        }
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1_024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(
            capacity: bufferSize
        )
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private extension PushRegistrationLoadingContext {
    func complete(
        _ stub: PushRegistrationURLProtocol.Stub,
        request: URLRequest
    ) {
        if let error = stub.error {
            loadingProtocol.client?.urlProtocol(
                loadingProtocol,
                didFailWithError: error
            )
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode ?? 500,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        loadingProtocol.client?.urlProtocol(
            loadingProtocol,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        if !stub.body.isEmpty {
            loadingProtocol.client?.urlProtocol(
                loadingProtocol,
                didLoad: stub.body
            )
        }
        loadingProtocol.client?.urlProtocolDidFinishLoading(
            loadingProtocol
        )
    }
}

final class PushRegistrationURLScript: @unchecked Sendable {
    private let lock = NSLock()
    private var stubs: [PushRegistrationURLProtocol.Stub] = []
    private var capturedRequests: [URLRequest] = []
    private var capturedBodies: [Data?] = []

    var requests: [URLRequest] {
        get async {
            lock.withLock { capturedRequests }
        }
    }

    var requestBodies: [Data?] {
        get async {
            lock.withLock { capturedBodies }
        }
    }

    func waitForRequestCount(
        _ expectedCount: Int,
        timeout: Duration = .seconds(1)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while lock.withLock({ capturedRequests.count }) < expectedCount {
            guard clock.now < deadline else { return false }
            try? await clock.sleep(for: .milliseconds(1))
        }
        return true
    }

    func reset(
        _ nextStubs: [PushRegistrationURLProtocol.Stub]
    ) async {
        lock.withLock {
            stubs = nextStubs
            capturedRequests = []
            capturedBodies = []
        }
    }

    func take(
        _ request: URLRequest,
        body: Data?
    ) -> PushRegistrationURLProtocol.Stub {
        lock.lock()
        defer { lock.unlock() }
        capturedRequests.append(request)
        capturedBodies.append(body)
        guard !stubs.isEmpty else {
            return .response(
                500,
                json: #"{"error":"unscripted_request"}"#
            )
        }
        return stubs.removeFirst()
    }
}
