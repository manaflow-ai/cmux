import CmuxNextDevices
@testable import CmuxNextMacScreen
import CmuxNextWakeups
import CmuxScreenKit
import CryptoKit
import Darwin
import Foundation
import Testing

// The acpmux daemon's share host and the app on one Mac (hq docs/design/remote-screen-share-zero-touch.md,
// Z5): the daemon decides who serves each host ticket and relays it with `servedBy`; the app serves only
// what is not the daemon's, and uses the daemon's device when its channel answers.

/// Software keys: tests only.
nonisolated private struct ServedByTestKeys: DeviceKeyMaterial {
    let signing = P256.Signing.PrivateKey()
    let agreement = P256.KeyAgreement.PrivateKey()
    var signingPublicKey: P256.Signing.PublicKey { signing.publicKey }
    var agreementPublicKey: P256.KeyAgreement.PublicKey { agreement.publicKey }
    func signature(for message: Data) throws -> P256.Signing.ECDSASignature { try signing.signature(for: message) }
    func open(_ ciphertext: Data, encapsulatedKey: Data, info: Data) throws -> Data { throw DeviceHubError.identity("test keys open nothing") }
}

/// Calls in order (a class: actor-isolated closures cannot capture a mutable local).
@MainActor
private final class ServedByCalls {
    var items: [String] = []
}

/// A signaling that stays open until closed (the host serves it meanwhile).
nonisolated private final class ServedByOpenSignaling: ScreenSignaling, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<ScreenSignal, any Error>.Continuation?
    func messages() -> AsyncThrowingStream<ScreenSignal, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ScreenSignal.self, throwing: (any Error).self)
        lock.withLock { self.continuation = continuation }
        return stream
    }
    func send(_ signal: ScreenSignal) async throws {}
    func iceServers() async throws -> [ICEServerConfig] { [] }
    func close() { lock.withLock { continuation }?.finish() }
    var endsSessionOnClose: Bool { true }
}

@MainActor
struct MacScreenHubHostServedByTests {
    private func hostTicket(_ id: String, servedBy: String?, peer: String = "v1") -> SessionTicket {
        SessionTicket(sessionId: id, ticket: "a.b.c", signalURL: URL(string: "wss://hub.invalid/v1/sessions/\(id)/ws")!, ice: [],
                      peer: .init(id: peer, name: "Studio", signingKey: "key"), role: .host, scope: .view, servedBy: servedBy)
    }

    /// A host with a consent gate that allows, logging every consent read, signaling made and /end.
    private func gatedHost() -> (MacScreenHubHost, ServedByCalls) {
        let file = FileManager.default.temporaryDirectory.appending(path: "mac-screen-\(UUID().uuidString)/mac-screen.json")
        let pages = MacScreenPages(store: MacScreenStore(file: file), work: BackgroundWork())
        let identity = DeviceIdentity(deviceID: UUID(), keys: ServedByTestKeys())
        let client = DeviceHubClient(baseURL: URL(string: "https://hub.invalid")!, identity: identity,
                                     tokens: DeviceHubAccountToken { throw DeviceHubError.notSignedIn })
        let hub = DeviceHub(client: client, secrets: MemoryRelaySecretStore(), deviceName: "Test Mac")
        let host = pages.hubHost
        let calls = ServedByCalls()
        host.hub = { hub }
        host.consentGate = { ticket in
            calls.items.append("consent \(ticket.sessionId)")
            return true
        }
        host.makeSignaling = { ticket, _ in
            calls.items.append("signaling \(ticket.sessionId)")
            return ServedByOpenSignaling()
        }
        host.endSession = { _, id, reason in calls.items.append("end \(id) \(reason)") }
        return (host, calls)
    }

    /// A ticket both see: the daemon got it too, and its relayed copy says who serves. The daemon's is
    /// not served here (no consent read, no host, no /end); the app's, or one with no `servedBy`, is
    /// served exactly as before.
    @Test(arguments: [String?.none, "app", "daemon"])
    func aTicketBothSeeIsServedOnlyByTheOneItNames(servedBy: String?) async {
        let (host, calls) = gatedHost()
        host.serve(hostTicket("s1", servedBy: servedBy))
        if servedBy == SessionTicket.servedByDaemon {
            for _ in 0..<200 { await Task.yield() }
            #expect(host.session == nil, "the daemon serves it")
            #expect(calls.items.isEmpty, "no consent read, no signaling, no /end")
        } else {
            for _ in 0..<1000 where host.session == nil { await Task.yield() }
            #expect(host.session?.id == "s1")
            #expect(calls.items == ["consent s1", "signaling s1"])
            host.sessionOver("s1")
        }
    }

    /// The app serving an iPhone viewer keeps it when the daemon takes a Mac viewer: nothing replaced or ended.
    @Test func aTicketTheDaemonServesNeverReplacesTheAppsSession() async {
        let (host, calls) = gatedHost()
        host.serve(hostTicket("s1", servedBy: "app"))
        for _ in 0..<1000 where host.session == nil { await Task.yield() }
        host.serve(hostTicket("s2", servedBy: SessionTicket.servedByDaemon, peer: "v2"))
        for _ in 0..<200 { await Task.yield() }
        #expect(host.session?.id == "s1")
        #expect(calls.items == ["consent s1", "signaling s1"])
        host.sessionOver("s1")
    }
}

struct SessionTicketServedByTests {
    @Test func servedByDecodesAndIsOptional() throws {
        let base = #""sessionId":"s1","ticket":"h.p.s","signalURL":"wss://hub.example/v1/sessions/s1/ws","ice":[],"peer":{"id":"v1","name":"Studio","signingKey":"K"},"role":"host","scope":"full""#
        func decoded(_ extra: String) -> SessionTicket? {
            guard case let .sessionTicket(ticket)? = DeviceHubPush(text: #"{"type":"session.ticket","# + base + extra + "}") else { return nil }
            return ticket
        }
        #expect(decoded("")?.servedBy == nil)
        #expect(decoded("")?.isServedByDaemon == false)
        #expect(decoded(#","servedBy":"app""#)?.servedBy == "app")
        #expect(decoded(#","servedBy":"app""#)?.isServedByDaemon == false)
        #expect(decoded(#","servedBy":"daemon""#)?.isServedByDaemon == true)
        // A value this build does not know keeps the ticket (the app serves it, as before).
        #expect(decoded(#","servedBy":"later""#)?.isServedByDaemon == false)
    }
}

/// The hub's HTTP API for these tests: `/v1/auth/stack` answers the user in `X-Test-User`; every
/// request is logged ("METHOD path") under the test's `X-Test-Log` key.
nonisolated private final class ShareHostHubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var logs: [String: [String]] = [:]

    static func requests(_ key: String) -> [String] { lock.withLock { logs[key] ?? [] } }

    /// A hub client whose requests this protocol answers, as `identity`, signed in as `user`.
    static func client(identity: DeviceIdentity, user: String, log key: String) -> DeviceHubClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ShareHostHubURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Test-User": user, "X-Test-Log": key]
        return DeviceHubClient(baseURL: URL(string: "https://hub.invalid")!, identity: identity,
                               tokens: DeviceHubAccountToken { "stack-token" }, session: URLSession(configuration: configuration))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let key = request.value(forHTTPHeaderField: "X-Test-Log") ?? ""
        Self.lock.withLock { Self.logs[key, default: []].append("\(request.httpMethod ?? "GET") \(url.path)") }
        let user = request.value(forHTTPHeaderField: "X-Test-User") ?? ""
        let body = url.path == "/v1/auth/stack" ? #"{"session":"hub-session","userId":"\#(user)","expiresAt":4102444800000}"# : "{}"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])
        if let response { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A User DO socket that never connects (these hubs only make HTTP calls).
nonisolated private struct NoSocketConnector: DeviceHubSocketConnector {
    func connect() async throws -> any DeviceHubSocketConnection { throw DeviceHubError.transport("no socket in this test") }
}

/// A hub on the daemon's device does not own it: the daemon registers it (with its join's settings)
/// and holds its sign-in, so the app's sign-out ends only its own sessions and never signs it out.
@MainActor
struct DaemonOwnedDeviceTests {
    private func testHub(ownsDevice: Bool, log: String) -> (DeviceHub, DeviceIdentity) {
        let identity = DeviceIdentity(deviceID: UUID(), keys: ServedByTestKeys())
        let hub = DeviceHub(client: ShareHostHubURLProtocol.client(identity: identity, user: "u", log: log),
                            socket: DeviceHubSocket(connector: NoSocketConnector()), secrets: MemoryRelaySecretStore(), deviceName: "Test Mac")
        hub.ownsDevice = ownsDevice
        return (hub, identity)
    }

    @Test(arguments: [true, false])
    func signOutSignsOutOnlyADeviceTheAppOwns(ownsDevice: Bool) async {
        let log = UUID().uuidString
        let (hub, identity) = testHub(ownsDevice: ownsDevice, log: log)
        await hub.signOut(ending: ["s1"], reason: "signed_out")
        let requests = ShareHostHubURLProtocol.requests(log).filter { $0 != "POST /v1/auth/stack" }
        if ownsDevice {
            #expect(requests == ["POST /v1/devices/\(identity.id)/sign-out"], "the hub ends the device's sessions itself")
        } else {
            #expect(requests == ["POST /v1/sessions/s1/end"], "no device sign-out: the daemon's shares go on")
        }
    }

    @Test(arguments: [true, false])
    func startRegistersOnlyADeviceTheAppOwns(ownsDevice: Bool) async {
        let log = UUID().uuidString
        let (hub, _) = testHub(ownsDevice: ownsDevice, log: log)
        await hub.start()
        hub.stop()
        #expect(ShareHostHubURLProtocol.requests(log).contains("POST /v1/devices") == ownsDevice)
    }
}

/// The daemon's device channel (`<acpmux home>/share-host/device.sock`), with a fake share host.
struct ShareHostDeviceTests {
    @Test func noChannelMeansNoDaemonDevice() async {
        let path = ShareHostDevice.socketPath(acpmuxHome: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString.prefix(8))"))
        #expect(path.hasSuffix("/share-host/device.sock"))
        #expect(await ShareHostDevice.identity(ShareHostDevice.channel(socketPath: path), socketPath: path) == nil)
    }

    @Test(.timeLimit(.minutes(1))) func aChannelThatAnswersGivesTheDaemonsIdentityAndUser() async throws {
        let id = UUID(), keys = ServedByTestKeys()
        let (path, daemon, done) = try shareHost(id: id, keys: keys, userID: "u")
        defer { done() }
        let found = await ShareHostDevice.identity(ShareHostDevice.channel(socketPath: path), socketPath: path)
        #expect(found?.identity.deviceID == id)
        #expect(found?.identity.keys.signingPublicKey.x963Representation == keys.signingPublicKey.x963Representation)
        #expect(found?.userID == "u")
        #expect(await daemon.value == ["host.mode", "device.identity"])
    }

    /// The daemon's device only for the app's own account: a missing or other `user_id` keeps the
    /// app's identity (nil here, so DeviceHubService falls back to the worker or the Secure Enclave).
    @MainActor @Test(.timeLimit(.minutes(1)), arguments: [String?.none, "other", "u"])
    func theDaemonsDeviceServesOnlyTheAppsAccount(daemonUser: String?) async throws {
        let (path, daemon, done) = try shareHost(id: UUID(), keys: ServedByTestKeys(), userID: daemonUser)
        defer { done() }
        let log = UUID().uuidString
        let hub = try await ShareHostDevice.daemonHub(ShareHostDevice.channel(socketPath: path), socketPath: path) { identity in
            DeviceHub(client: ShareHostHubURLProtocol.client(identity: identity, user: "u", log: log),
                      socket: DeviceHubSocket(connector: NoSocketConnector()), secrets: MemoryRelaySecretStore(), deviceName: "Test Mac")
        }
        _ = await daemon.value
        if daemonUser == "u" {
            #expect(hub != nil && hub?.ownsDevice == false, "the daemon registers and signs in its device")
        } else {
            #expect(hub == nil)
        }
        #expect(!ShareHostHubURLProtocol.requests(log).contains("POST /v1/devices"))
    }

    /// A fake share host at a fresh `<home>/share-host/device.sock`: one connection, answered until
    /// `device.identity` (with `userID` as `user_id` when given), then closed. Returns the methods it heard.
    private func shareHost(id: UUID, keys: ServedByTestKeys, userID: String?) throws -> (String, Task<[String], Never>, () -> Void) {
        let home = URL(fileURLWithPath: "/tmp/shd-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appending(path: "share-host"), withIntermediateDirectories: true)
        let path = ShareHostDevice.socketPath(acpmuxHome: home)
        let listener = try listen(path)
        var identity: [String: Any] = ["id": id.uuidString, "signing_key": keys.signingPublicKey.x963Representation.base64EncodedString(),
                                       "agreement_key": keys.agreementPublicKey.x963Representation.base64EncodedString()]
        if let userID { identity["user_id"] = userID }
        let encoded = ["device.identity": (try? JSONSerialization.data(withJSONObject: identity)) ?? Data()]
        // task-owner: this test's fake share host; ends after device.identity or EOF.
        let daemon = Task.detached(priority: .userInitiated) { () -> [String] in
            defer { Darwin.close(listener) }
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return [] }
            defer { Darwin.close(connection) }
            var methods: [String] = []
            while let line = RemoteSocket.readLine(connection),
                  let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let requestID = request["id"] as? Int, let method = request["method"] as? String {
                methods.append(method)
                let result = encoded[method].flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                guard RemoteSocket.writeAll(connection, Data(#"{"id":\#(requestID),"ok":true,"result":\#(result)}"#.utf8) + Data([0x0A])) else { break }
                if method == "device.identity" { break }
            }
            return methods
        }
        return (path, daemon, { try? FileManager.default.removeItem(at: home) })
    }

    private func listen(_ path: String) throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(descriptor >= 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0 && Darwin.listen(descriptor, 1) == 0)
        return descriptor
    }
}
