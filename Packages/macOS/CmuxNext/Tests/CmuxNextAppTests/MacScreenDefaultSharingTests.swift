import CmuxNextCompat
import CmuxNextDevices
@testable import CmuxNextMacScreen
import CmuxNextWakeups
import CryptoKit
import Foundation
import Testing

// Sharing on by default (Leo, 2026-11-16: "if you have indeed connected a machine, you should be able
// to just screen share onto it freely"): a signed-in Mac with Screen Recording granted turns its hub bit
// on by itself; the person's off stays off across relaunch, update and sign-out/sign-in; a revoked grant
// turns the bit off and reads needs_grant; sign-out clears the bit.

nonisolated private struct DefaultSharingKeys: DeviceKeyMaterial {
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

/// The hub: lists this Mac (shared or not) and answers its sharing write; counts the writes per test.
nonisolated private final class DefaultSharingHubProtocol: URLProtocol, @unchecked Sendable {
    static let writes = Mutex<[String: [Bool]]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let test = request.value(forHTTPHeaderField: "X-Test-ID") ?? ""
        let me = request.value(forHTTPHeaderField: "X-Test-Me") ?? ""
        let shared = request.value(forHTTPHeaderField: "X-Test-Shared") == "1"
        let body: String
        if url.path == "/v1/auth/stack" {
            body = #"{"session":"hub-session","userId":"u","expiresAt":4102444800000}"#
        } else if url.path.hasSuffix("/mac-screen"), request.httpMethod == "PUT" {
            let on = Self.bodyData(request).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["shared"] as? Bool ?? false
            Self.writes.withLock { $0[test, default: []].append(on) }
            body = #"{"device":{"id":"\#(me)","name":"This Mac","platform":"macos","online":true,"macScreenShared":\#(on)}}"#
        } else {
            body = #"{"devices":[{"id":"\#(me)","name":"This Mac","platform":"macos","online":true,"macScreenShared":\#(shared)}]}"#
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])
        if let response { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

@MainActor @Suite(.serialized)
struct MacScreenDefaultSharingTests {
    /// A signed-in hub that lists this Mac with its sharing bit `shared`.
    private func hub(shared: Bool, test: String = UUID().uuidString) async -> DeviceHub {
        let identity = DeviceIdentity(deviceID: UUID(), keys: DefaultSharingKeys())
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DefaultSharingHubProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Test-ID": test, "X-Test-Me": identity.id, "X-Test-Shared": shared ? "1" : "0"]
        let client = DeviceHubClient(baseURL: URL(string: "https://hub.invalid")!, identity: identity,
                                     tokens: DeviceHubAccountToken { "stack-token" }, session: URLSession(configuration: configuration))
        let hub = DeviceHub(client: client, secrets: MemoryRelaySecretStore(), deviceName: "This Mac")
        await hub.refreshDevices()
        return hub
    }

    private func file() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "mac-screen-\(UUID().uuidString)/mac-screen.json")
    }

    /// Pages on `file` (read), with Screen Recording `granted`, the host on `hub`, and its writes recorded.
    private func makePages(_ file: URL, hub: DeviceHub, granted: Bool) async -> (MacScreenPages, Writes) {
        let pages = MacScreenPages(store: MacScreenStore(file: file), work: BackgroundWork())
        await pages.store.load()
        pages.host.readPermissions = { (granted, false) }
        await pages.host.refreshPermissions()
        let writes = Writes()
        pages.hubHost.hub = { hub }
        pages.hubHost.writeSharing = { _, on in writes.items.append(on) }
        return (pages, writes)
    }

    @MainActor final class Writes {
        var items: [Bool] = []
    }

    @Test func eachStateTakesItsStep() {
        typealias Host = MacScreenHubHost
        // Never set: on.
        #expect(Host.defaultSharingStep(shared: false, grantKnown: true, screenRecording: true, turnedOff: false) == .turnOn)
        // The person turned it off: it stays off.
        #expect(Host.defaultSharingStep(shared: false, grantKnown: true, screenRecording: true, turnedOff: true) == .none)
        // The grant was revoked: off, on or off by the person alike.
        #expect(Host.defaultSharingStep(shared: true, grantKnown: true, screenRecording: false, turnedOff: false) == .turnOff)
        #expect(Host.defaultSharingStep(shared: true, grantKnown: true, screenRecording: false, turnedOff: true) == .turnOff)
        // No grant yet: nothing turns on.
        #expect(Host.defaultSharingStep(shared: false, grantKnown: true, screenRecording: false, turnedOff: false) == .none)
        // Unknown hub record, unread grant or unread store: wait.
        #expect(Host.defaultSharingStep(shared: nil, grantKnown: true, screenRecording: true, turnedOff: false) == .none)
        #expect(Host.defaultSharingStep(shared: true, grantKnown: false, screenRecording: false, turnedOff: false) == .none)
        #expect(Host.defaultSharingStep(shared: false, grantKnown: true, screenRecording: true, turnedOff: nil) == .none)
        // On and granted: nothing to do.
        #expect(Host.defaultSharingStep(shared: true, grantKnown: true, screenRecording: true, turnedOff: false) == .none)
    }

    @Test func theMachineRecordNamesTheState() {
        typealias Host = MacScreenHubHost
        #expect(Host.sharingState(shared: true, grantKnown: true, screenRecording: false, turnedOff: false) == .needsGrant)
        #expect(Host.sharingState(shared: false, grantKnown: true, screenRecording: false, turnedOff: true) == .needsGrant)
        #expect(Host.sharingState(shared: true, grantKnown: true, screenRecording: true, turnedOff: false) == .on)
        #expect(Host.sharingState(shared: false, grantKnown: true, screenRecording: true, turnedOff: true) == .turnedOff)
        #expect(Host.sharingState(shared: false, grantKnown: true, screenRecording: true, turnedOff: false) == .off)
        #expect(Host.SharingState.needsGrant.rawValue == "needs_grant")
    }

    /// A Mac that joined the account, with Screen Recording granted and no choice made, shares by itself.
    @Test func neverSetTurnsOn() async {
        let (pages, writes) = await makePages(file(), hub: await hub(shared: false), granted: true)
        await pages.hubHost.followDefaultSharing()
        #expect(writes.items == [true])
        #expect(!pages.store.sharingTurnedOff, "the default is not the person's choice")
    }

    /// The watch MacScreenPages runs while signed in takes that step with nobody at the Mac.
    @Test(.timeLimit(.minutes(1))) func signingInTurnsItOnWithNobodyAtTheMac() async throws {
        let hub = await hub(shared: false)
        let (pages, _) = await makePages(file(), hub: hub, granted: true)
        let (written, sink) = AsyncStream.makeStream(of: Bool.self)
        pages.hubHost.writeSharing = { _, on in sink.yield(on) }
        pages.hub = hub
        let first = await Task { () -> Bool? in
            for await on in written { return on }
            return nil
        }.value
        #expect(first == true)
        pages.hub = nil
    }

    /// The person's off stays off: after a relaunch (a new store on the same file), and across
    /// sign-out and sign-in.
    @Test func turnedOffStaysOffAcrossRelaunchAndSignIn() async {
        let file = file()
        let hubOn = await hub(shared: true)
        let (first, _) = await makePages(file, hub: hubOn, granted: true)
        try? await first.hubHost.setSharing(false)
        #expect(first.store.sharingTurnedOff)
        await first.store.flush()

        let (relaunched, writes) = await makePages(file, hub: await hub(shared: false), granted: true)
        #expect(relaunched.store.sharingTurnedOff)
        await relaunched.hubHost.followDefaultSharing()
        #expect(writes.items.isEmpty)

        // Sign out, then in again (another hub): still off, and nothing written.
        relaunched.hub = await hub(shared: false)
        relaunched.hub = nil
        let again = await hub(shared: false)
        relaunched.hubHost.hub = { again }
        await relaunched.hubHost.followDefaultSharing()
        #expect(writes.items.isEmpty)
        #expect(relaunched.store.sharingTurnedOff)

        // Turning it on again is the person's too: the default may follow it again.
        try? await relaunched.hubHost.setSharing(true, requestPermissions: false)
        #expect(!relaunched.store.sharingTurnedOff)
    }

    /// An update from a build without the switch: a Mac that shared once and is off now was turned off.
    @Test(arguments: [true, false])
    func anUpdateReadsAnEarlierShareAsTurnedOff(sharedBefore: Bool) async throws {
        let file = file()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"deviceNames":{},"hasSharedBefore":\#(sharedBefore),"hasViewedBefore":false,"linkPairingsRemoved":true}"#.utf8).write(to: file)
        let (pages, writes) = await makePages(file, hub: await hub(shared: false), granted: true)
        #expect(pages.store.sharingTurnedOff == sharedBefore)
        await pages.hubHost.followDefaultSharing()
        #expect(writes.items == (sharedBefore ? [] : [true]))
    }

    /// The same update on a Mac the hub shows sharing: it was never turned off, so the default applies.
    @Test func anUpdatedMacSeenSharingIsNotTurnedOff() async throws {
        let file = file()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"deviceNames":{},"hasSharedBefore":true,"hasViewedBefore":false,"linkPairingsRemoved":true}"#.utf8).write(to: file)
        let (pages, _) = await makePages(file, hub: await hub(shared: true), granted: true)
        #expect(pages.store.sharingTurnedOff)
        pages.hostSharingChanged(true)
        #expect(!pages.store.sharingTurnedOff)
    }

    /// The grant revoked: the bit goes off by itself, the record reads needs_grant, and it is not the
    /// person's off, so a new grant turns it on again.
    @Test func aRevokedGrantTurnsItOffAndNeedsAGrant() async {
        let (pages, writes) = await makePages(file(), hub: await hub(shared: true), granted: false)
        #expect(pages.hubHost.sharingState == .needsGrant)
        await pages.hubHost.followDefaultSharing()
        #expect(writes.items == [false])
        #expect(!pages.store.sharingTurnedOff)
    }

    /// A failed permission read never turns sharing off.
    @Test func aFailedReadLeavesSharingAlone() async {
        let (pages, writes) = await makePages(file(), hub: await hub(shared: true), granted: true)
        pages.host.readPermissions = { throw CancellationError() }
        await pages.host.refreshPermissions()
        #expect(!pages.host.permissionsKnown)
        await pages.hubHost.followDefaultSharing()
        #expect(writes.items.isEmpty)
    }

    /// Sign-out clears the bit at the hub (its own sign-out keeps it), and writes nothing when it is off.
    @Test func signOutClearsTheBit() async {
        let test = UUID().uuidString
        let on = await hub(shared: true, test: test)
        await DeviceHubService.clearSharing(on)
        #expect(DefaultSharingHubProtocol.writes.withLock { $0[test] } == [false])
        #expect(on.thisDevice?.macScreenShared == false)

        let quiet = UUID().uuidString
        await DeviceHubService.clearSharing(await hub(shared: false, test: quiet))
        #expect(DefaultSharingHubProtocol.writes.withLock { $0[quiet] } == nil)
    }
}
