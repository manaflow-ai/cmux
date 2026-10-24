import Foundation
import Testing

@testable import CmuxPhoneControl

@Suite("cmux.phone WebDriverAgent adapter", .serialized)
struct WebDriverAgentDriverTests {
    @Test
    func adapterCompletesDiscoveryObservationAndInputAgainstWDAContract() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubWDAURLProtocol.self]
        let session = URLSession(configuration: configuration)
        StubWDAURLProtocol.recorder.reset()

        let driver = WebDriverAgentDriver(
            configuration: .init(baseURL: URL(string: "http://127.0.0.1:8100")!),
            urlSession: session
        )

        let device = try await driver.device()
        #expect(device.geometry.width == 428)
        #expect(device.geometry.height == 926)
        #expect(device.capabilities.tap)
        #expect(!device.capabilities.screenStream)

        let frame = try await driver.snapshot()
        #expect(frame.data == Data("fake-png".utf8))
        #expect(frame.width == 428)
        #expect(frame.height == 926)

        let tree = try #require(try await driver.accessibilityTree())
        #expect(tree.bounds == .init(x: 0, y: 0, width: 1, height: 1))
        let button = try #require(tree.children.first)
        #expect(button.label == "Continue")
        #expect(button.bounds.x == 42.0 / 428.0)

        let receipt = try await driver.perform(.init(
            actionID: "tap-1",
            kind: .tap,
            point: .init(x: 0.5, y: 0.25)
        ))
        #expect(receipt.accepted)
        #expect(receipt.screenSequence == 2)

        let requests = StubWDAURLProtocol.recorder.requests
        #expect(requests.map { $0.request.url?.path } == [
            "/status",
            "/session",
            "/session/session-1/window/size",
            "/session/session-1/window/size",
            "/session/session-1/screenshot",
            "/session/session-1/window/size",
            "/session/session-1/source",
            "/session/session-1/window/size",
            "/session/session-1/wda/tap",
        ])
        let tapBody = try #require(requests.last?.body)
        let tapJSON = try #require(JSONSerialization.jsonObject(with: tapBody) as? [String: Any])
        #expect((tapJSON["x"] as? Double) == 214)
        #expect((tapJSON["y"] as? Double) == 231.5)
    }

    @Test
    func unreadyWDAIsReportedBeforeSessionCreation() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubWDAURLProtocol.self]
        let session = URLSession(configuration: configuration)
        StubWDAURLProtocol.recorder.reset()
        StubWDAURLProtocol.recorder.setReady(false)
        defer { StubWDAURLProtocol.recorder.setReady(true) }

        let driver = WebDriverAgentDriver(
            configuration: .init(baseURL: URL(string: "http://127.0.0.1:8100")!),
            urlSession: session
        )

        await #expect(throws: PhoneDriverError.unavailable("WebDriverAgent is not ready")) {
            _ = try await driver.device()
        }
        #expect(StubWDAURLProtocol.recorder.requests.map { $0.request.url?.path } == ["/status"])
    }

    @Test
    func oversizedWDAResponsesAreRejectedWhileStreaming() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubWDAURLProtocol.self]
        let session = URLSession(configuration: configuration)
        StubWDAURLProtocol.recorder.reset()
        StubWDAURLProtocol.recorder.setOversizedScreenshot(true)
        defer { StubWDAURLProtocol.recorder.setOversizedScreenshot(false) }

        let driver = WebDriverAgentDriver(
            configuration: .init(baseURL: URL(string: "http://127.0.0.1:8100")!),
            urlSession: session
        )
        _ = try await driver.device()

        await #expect(throws: PhoneDriverError.malformedResponse(
            "WDA response exceeded the bounded response size"
        )) {
            _ = try await driver.snapshot()
        }
    }

    @Test
    func nonLoopbackEndpointsAreRejectedBeforeNetworkAccess() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubWDAURLProtocol.self]
        let session = URLSession(configuration: configuration)
        StubWDAURLProtocol.recorder.reset()

        let driver = WebDriverAgentDriver(
            configuration: .init(baseURL: URL(string: "http://example.invalid:8100")!),
            urlSession: session
        )

        await #expect(throws: PhoneDriverError.transport("WDA endpoint must be loopback HTTP(S)")) {
            _ = try await driver.device()
        }
        #expect(StubWDAURLProtocol.recorder.requests.isEmpty)
    }
}

private final class StubWDAURLProtocol: URLProtocol, @unchecked Sendable {
    static let recorder = WDARequestRecorder()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "http"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.recorder.record(request)
        let path = request.url?.path ?? ""
        let body: Data
        switch path {
        case "/status":
            let status = Self.recorder.isReady ? "true" : "false"
            body = Data("{\"value\":{\"ready\":\(status)}}".utf8)
        case "/session":
            body = Data(#"{"value":{"sessionId":"session-1"},"sessionId":"session-1"}"#.utf8)
        case "/session/session-1/window/size":
            body = Data(#"{"value":{"width":428,"height":926}}"#.utf8)
        case "/session/session-1/screenshot":
            body = Self.recorder.oversizedScreenshot
                ? Data(repeating: 0x20, count: PhoneProtocol.maxResponseLineBytes + 1)
                : Data(#"{"value":"ZmFrZS1wbmc="}"#.utf8)
        case "/session/session-1/source":
            body = Data(
                #"{"value":{"type":"XCUIElementTypeApplication","label":"Demo","frame":{"x":0,"y":0,"width":428,"height":926},"children":[{"type":"XCUIElementTypeButton","label":"Continue","frame":{"x":42,"y":100,"width":200,"height":48}}]}}"#.utf8
            )
        default:
            body = Data(#"{"value":null}"#.utf8)
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class WDARequestRecorder: @unchecked Sendable {
    struct Capture: @unchecked Sendable {
        let request: URLRequest
        let body: Data?
    }

    private let lock = NSLock()
    private var storedRequests: [Capture] = []
    private var ready = true
    private var oversizedScreenshotEnabled = false

    var isReady: Bool {
        lock.withLock { ready }
    }

    var requests: [Capture] {
        lock.withLock { storedRequests }
    }

    var oversizedScreenshot: Bool {
        lock.withLock { oversizedScreenshotEnabled }
    }

    func record(_ request: URLRequest) {
        let body = request.httpBody ?? request.httpBodyStream.flatMap(Self.read)
        lock.withLock { storedRequests.append(.init(request: request, body: body)) }
    }

    func reset() {
        lock.withLock {
            storedRequests.removeAll()
            ready = true
            oversizedScreenshotEnabled = false
        }
    }

    func setReady(_ value: Bool) {
        lock.withLock { ready = value }
    }

    func setOversizedScreenshot(_ value: Bool) {
        lock.withLock { oversizedScreenshotEnabled = value }
    }

    private static func read(_ stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4 * 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}
