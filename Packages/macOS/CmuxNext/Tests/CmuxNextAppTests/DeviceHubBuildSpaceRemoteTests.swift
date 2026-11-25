import CmuxNextActions
import CmuxNextCompat
import CmuxNextDevices
@testable import CmuxNextMacScreen
import CmuxNextSettings
import CmuxNextWakeups
import CryptoKit
import Foundation
import Testing

/// A tagged dev build with cmux Remote running (PR 55026 review). DEV builds embed the pinned cmux Remote (dev), whose
/// worker predates build spaces: it renews its device and opens its User DO socket without `X-Cmux-Build-Space`, so a
/// tag's Mac served by it was never online in the tag's space and the tag's iPhone could not share it. In a dev build
/// space the app's own hub serves instead, and it names the space on every call; NIGHTLY and release keep the worker's.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct DeviceHubBuildSpaceRemoteTests {
    @Test func aTaggedDevBuildWithCmuxRemoteRunningRegistersAndRenewsInItsOwnSpace() async throws {
        let space = DeviceHubBuildSpace.dev("dev:tag-a")
        let run = Run(space: space)
        defer { run.service.willSignOut() }
        let installed = try await run.installed()
        #expect(installed === run.appHub, "the app's own hub serves a tagged dev build")
        #expect(run.remoteAsked == 0, "cmux Remote's hub is never made: its worker renews in NIGHTLY's space")
        await run.registered(installed)
        // The session exchange (the hub binds the session to the space) and the registration, and every other call, in the
        // tag's space.
        let requests = BuildSpaceHubProtocol.requests(run.log)
        #expect(Set(requests.map(\.line)).isSuperset(of: ["POST /v1/auth/stack", "POST /v1/devices"]))
        #expect(requests.allSatisfy { $0.space == "dev:tag-a" })
        #expect(installed.status == .ready)
        // The User DO socket, which keeps the Mac online in its space and brings its tickets, names the space too.
        #expect(try await installed.client.userSocketHandshake().headers[DeviceHubBuildSpace.headerName] == "dev:tag-a")
    }

    /// No build space (NIGHTLY, release): cmux Remote's hub serves this Mac exactly as before.
    @Test func nightlyKeepsCmuxRemotesHub() async throws {
        let run = Run(space: .nightly)
        defer { run.service.willSignOut() }
        let installed = try await run.installed()
        #expect(installed === run.workerHub)
        #expect(run.remoteAsked == 1)
        await run.registered(installed)
        #expect(BuildSpaceHubProtocol.requests(run.log).allSatisfy { $0.space == nil })
    }

    /// A signed-in DeviceHubService in `space`, with cmux Remote running (its factory answers a hub) and the app's own
    /// identity; both hubs talk to ``BuildSpaceHubProtocol``.
    @MainActor final class Run {
        let service: DeviceHubService
        let appHub: DeviceHub, workerHub: DeviceHub
        let log: String
        private(set) var remoteAsked = 0
        private let changes: AsyncStream<DeviceHub?>

        init(space: DeviceHubBuildSpace) {
            let file = FileManager.default.temporaryDirectory.appending(path: "hub-space-\(UUID().uuidString)/screen.json")
            let pages = MacScreenPages(store: MacScreenStore(file: file, removeLinkPairings: {}), work: BackgroundWork())
            let settings = SettingsController(writer: TestSettingsWriter(), registry: ActionRegistry(),
                                              fileURL: file.deletingLastPathComponent().appending(path: "config.json"))
            let log = UUID().uuidString
            let appHub = Self.hub(space: space, log: log), workerHub = Self.hub(space: space, log: log)
            let (changes, report) = AsyncStream<DeviceHub?>.makeStream()
            self.log = log
            self.appHub = appHub
            self.workerHub = workerHub
            self.changes = changes
            service = DeviceHubService(pages: pages, account: .init(awaitRestored: {}, userID: { "account" }, accessToken: { "stack-token" }),
                                       bundleIdentifier: "test.hub-space", loginKeychain: LoginKeychain(),
                                       selectedBaseURL: URL(string: "https://hub.invalid"), buildSpace: space,
                                       makeAppHub: { _, _, _, _, _ in appHub })
            // cmux Remote running: its factory answers the hub made with the worker's device.
            service.makeRemoteHub = { [weak self] _, _ in
                self?.remoteAsked += 1
                return workerHub
            }
            service.hubChanged = { hub, _, _ in report.yield(hub) }
            service.start(settings: settings)
        }

        /// The first hub the service installs.
        func installed() async throws -> DeviceHub {
            for await hub in changes { if let hub { return hub } }
            throw CancellationError()
        }

        /// Waits for the installed hub's first registration to end.
        func registered(_ hub: DeviceHub) async {
            for await status in ObservationStream({ hub.status }) where status != .idle && status != .starting { return }
        }

        private static func hub(space: DeviceHubBuildSpace, log: String) -> DeviceHub {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [BuildSpaceHubProtocol.self]
            configuration.httpAdditionalHeaders = ["X-Test-Log": log]
            let client = DeviceHubClient(baseURL: URL(string: "https://hub.invalid")!, identity: DeviceIdentity(deviceID: UUID(), keys: Keys()),
                                         tokens: DeviceHubAccountToken { "stack-token" }, buildSpace: space,
                                         session: URLSession(configuration: configuration))
            return DeviceHub(client: client, socket: DeviceHubSocket(connector: NoSocket()), secrets: MemoryRelaySecretStore(),
                             deviceName: "Test Mac")
        }
    }

    nonisolated private struct NoSocket: DeviceHubSocketConnector {
        func connect() async throws -> any DeviceHubSocketConnection { throw DeviceHubError.transport("no socket in this test") }
    }

    nonisolated private struct Keys: DeviceKeyMaterial {
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
}

/// The hub's HTTP API for these tests: `/v1/auth/stack` signs in `account`, `/v1/devices` registers the device. Every
/// request is logged ("METHOD path" and its build space header) under the test's `X-Test-Log` key.
nonisolated private final class BuildSpaceHubProtocol: URLProtocol, @unchecked Sendable {
    struct Request: Sendable {
        var line: String
        var space: String?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var logs: [String: [Request]] = [:]

    static func requests(_ key: String) -> [Request] { lock.withLock { logs[key] ?? [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let key = request.value(forHTTPHeaderField: "X-Test-Log") ?? ""
        let line = "\(request.httpMethod ?? "GET") \(url.path)"
        let entry = Request(line: line, space: request.value(forHTTPHeaderField: DeviceHubBuildSpace.headerName))
        Self.lock.withLock { Self.logs[key, default: []].append(entry) }
        let body = switch line {
        case "POST /v1/auth/stack": #"{"session":"hub-session","userId":"account","expiresAt":4102444800000}"#
        case "POST /v1/devices":
            #"{"device":{"id":"6f1c2a4e-0d3b-4c5a-9e7f-112233445566","name":"Test Mac","platform":"macos","macScreenShared":0,"online":true}}"#
        default: "{}"
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])
        if let response { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
