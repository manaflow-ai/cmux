import CryptoKit
@testable import CmuxDeviceHub
import Foundation

/// Software keys: tests only. The app's keys are always in the Secure Enclave.
struct SoftwareDeviceKeys: DeviceKeyMaterial {
    let signing = P256.Signing.PrivateKey()
    let agreement = P256.KeyAgreement.PrivateKey()

    var signingPublicKey: P256.Signing.PublicKey { signing.publicKey }
    var agreementPublicKey: P256.KeyAgreement.PublicKey { agreement.publicKey }

    func signature(for message: Data) throws -> P256.Signing.ECDSASignature { try signing.signature(for: message) }

    func open(_ ciphertext: Data, encapsulatedKey: Data, info: Data) throws -> Data {
        var recipient = try HPKE.Recipient(privateKey: agreement, ciphersuite: RelaySealing.ciphersuite, info: info,
                                           encapsulatedKey: encapsulatedKey)
        return try recipient.open(ciphertext)
    }
}

extension DeviceIdentity {
    static func software(_ id: String = "6f1c2a4e-0d3b-4c5a-9e7f-112233445566") -> DeviceIdentity {
        DeviceIdentity(deviceID: UUID(uuidString: id)!, keys: SoftwareDeviceKeys())
    }
}

/// A fixed clock: 1_800_000_000 (2027-01-15).
let fixedNow: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_800_000_000) }

/// One recorded request: URLSession hands a URLProtocol the body as a stream.
struct RecordedRequest: Sendable {
    var method: String
    var url: URL
    var headers: [String: String]
    var body: Data?

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var pathAndQuery: String { DeviceRequestSigner.pathAndQuery(of: url) }

    var jsonBody: [String: Any]? {
        body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}

/// A scripted hub behind URLProtocol, one per test (keyed by host name).
final class StubHub: @unchecked Sendable {
    // @unchecked: state behind `lock`.
    typealias Handler = @Sendable (RecordedRequest) -> (Int, String)

    private let lock = NSLock()
    private var handler: Handler
    private var recorded: [RecordedRequest] = []
    let host: String

    init(handler: @escaping Handler) {
        host = "hub-\(UUID().uuidString.lowercased()).test"
        self.handler = handler
        StubURLProtocol.register(self)
    }

    var baseURL: URL { URL(string: "https://\(host)")! }
    var requests: [RecordedRequest] { lock.withLock { recorded } }

    func setHandler(_ handler: @escaping Handler) { lock.withLock { self.handler = handler } }

    func answer(_ request: RecordedRequest) -> (Int, String) {
        let handler = lock.withLock { () -> Handler in
            recorded.append(request)
            return self.handler
        }
        return handler(request)
    }

    /// A session whose requests go to the registered stubs.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }()

    /// The account exchange plus `routes` by "METHOD path" (path without query).
    static func routes(_ routes: [String: (Int, String)]) -> StubHub {
        StubHub { request in
            if request.url.path == "/v1/auth/stack" {
                return (200, #"{"session":"hub-session","userId":"user-1","expiresAt":1800003600000}"#)
            }
            return routes["\(request.method) \(request.url.path)"] ?? (404, #"{"error":{"code":"not_found","message":"no route"}}"#)
        }
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var hubs: [String: StubHub] = [:]

    static func register(_ hub: StubHub) { lock.withLock { hubs[hub.host] = hub } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let hub = Self.lock.withLock({ Self.hubs[url.host ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            body = data
        }
        let recorded = RecordedRequest(method: request.httpMethod ?? "GET", url: url,
                                       headers: request.allHTTPHeaderFields ?? [:], body: body)
        let (status, text) = hub.answer(recorded)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

func makeClient(_ hub: StubHub, identity: DeviceIdentity = .software(), token: String = "stack-token") -> DeviceHubClient {
    DeviceHubClient(baseURL: hub.baseURL, identity: identity, tokens: DeviceHubAccountToken { token },
                    session: StubHub.session, now: fixedNow)
}
