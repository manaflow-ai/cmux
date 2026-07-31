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
        let context = PushRegistrationLoadingContext(
            loadingProtocol: self
        )
        Task.detached { [capturedRequest, context] in
            let loadingProtocol = context.loadingProtocol
            let stub = await Self.script.take(capturedRequest)
            await stub.started?.markStarted()
            await stub.blocker?.wait()
            if let error = stub.error {
                loadingProtocol.client?.urlProtocol(
                    loadingProtocol,
                    didFailWithError: error
                )
                return
            }
            let response = HTTPURLResponse(
                url: capturedRequest.url!,
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

    override func stopLoading() {}
}

actor PushRegistrationURLScript {
    private var stubs: [PushRegistrationURLProtocol.Stub] = []
    private(set) var requests: [URLRequest] = []

    func reset(_ nextStubs: [PushRegistrationURLProtocol.Stub]) {
        stubs = nextStubs
        requests = []
    }

    func take(_ request: URLRequest) -> PushRegistrationURLProtocol.Stub {
        requests.append(request)
        guard !stubs.isEmpty else {
            return .response(500, json: #"{"error":"unscripted_request"}"#)
        }
        return stubs.removeFirst()
    }
}
