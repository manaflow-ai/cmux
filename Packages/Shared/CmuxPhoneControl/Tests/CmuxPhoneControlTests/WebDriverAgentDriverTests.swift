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
            "/window/size",
            "/screenshot",
            "/source",
            "/wda/tap",
        ])
        let tapBody = try #require(requests.last?.body)
        let tapJSON = try #require(JSONSerialization.jsonObject(with: tapBody) as? [String: Any])
        #expect((tapJSON["x"] as? Double) == 214)
        #expect((tapJSON["y"] as? Double) == 231.5)
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
            body = Data(#"{"value":{"ready":true}}"#.utf8)
        case "/window/size":
            body = Data(#"{"value":{"width":428,"height":926}}"#.utf8)
        case "/screenshot":
            body = Data(#"{"value":"ZmFrZS1wbmc="}"#.utf8)
        case "/source":
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

    var requests: [Capture] {
        lock.withLock { storedRequests }
    }

    func record(_ request: URLRequest) {
        let body = request.httpBody ?? request.httpBodyStream.flatMap(Self.read)
        lock.withLock { storedRequests.append(.init(request: request, body: body)) }
    }

    func reset() {
        lock.withLock { storedRequests.removeAll() }
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
