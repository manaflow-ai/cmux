import CmuxNextCompat
public import CmuxNextDevices
import CryptoKit
import Darwin
import Foundation

/// This Mac's device hub identity when cmux Remote serves it (docs/cmux-remote.md, Screen
/// Sharing worker): the worker owns the Secure Enclave keys and the one User DO socket of this
/// device. This app signs its own (viewer) requests through the worker, so the Mac is one
/// device, and reads the hub's pushes from the worker's socket (a second socket of the same
/// device would replace the first).
public nonisolated final class CmuxRemoteDevices: Sendable {
    /// Opens a Screen Sharing channel through the host (the App's ``CmuxRemoteService``).
    let open: @Sendable () async throws -> Int32
    private let control = Mutex<RemoteDeviceChannel?>(nil)
    /// One subscription channel's pushes, for this app's hub socket.
    private let subscription = Mutex<RemoteDeviceChannel?>(nil)

    init(open: @escaping @Sendable () async throws -> Int32) {
        self.open = open
    }

    /// This Mac's join consent now (the App sets it): sent first on every new channel, so a
    /// restarted worker serves nothing the person has not allowed (it refuses until it hears it).
    let consentNow = Mutex<(@Sendable () async -> (enabled: Bool, view: Bool, full: Bool))?>(nil)

    public func setConsentSource(_ source: @escaping @Sendable () async -> (enabled: Bool, view: Bool, full: Bool)) {
        consentNow.store(source)
    }

    /// The request channel, opened on first use and again after it ends (a worker or host restart).
    private func channel() async throws -> RemoteDeviceChannel {
        if let live = control.withLock({ $0 }), live.isOpen { return live }
        let fresh = RemoteDeviceChannel(socket: try await open())
        do {
            _ = try await fresh.call("host.mode", ["mode": "relay-only"])
            if let source = consentNow.load() {
                let consent = await source()
                _ = try? await fresh.call("consent", ["enabled": consent.enabled, "view": consent.view, "full": consent.full])
            }
        } catch {
            fresh.close()
            throw error
        }
        // Two simultaneous signing requests may open channels together. Keep one; an orphan
        // channel would keep worker hosting disabled even after the app's real channel closes.
        let selected = control.withLock { current in
            if let live = current, live.isOpen { return live }
            current = fresh
            return fresh
        }
        if selected !== fresh { fresh.close() }
        return selected
    }

    /// This device's identity from the worker (its keys stay in the worker's Secure Enclave).
    func identity(renew: Bool = false) async throws -> DeviceIdentity {
        let answer = try await channel().call(renew ? "device.renew" : "device.identity")
        return try makeIdentity(answer)
    }

    /// The renewal closure supplied to ``DeviceHub`` is synchronous and is
    /// invoked off the main actor. Use the same bounded request channel as
    /// signing to fetch a fresh worker identity when the hub rejected this
    /// device as removed or key-mismatched.
    func blockingIdentity(renew: Bool = false) throws -> DeviceIdentity {
        try makeIdentity(try blockingCall(renew ? "device.renew" : "device.identity", [:]))
    }

    /// ``blockingIdentity(renew:)`` and the hub user the device signed in as (`user_id`: the acpmux
    /// daemon's share host sends it while its machine sign-in holds; nil otherwise).
    func blockingIdentityAndUser() throws -> (identity: DeviceIdentity, userID: String?) {
        let answer = try blockingCall("device.identity", [:])
        return (try makeIdentity(answer), (answer["user_id"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    /// The app's hub as this channel's device: `identity` (from ``identity(renew:)``) signs through
    /// the channel, and the channel's pushes are the hub's socket. Used for the cmux Remote worker
    /// and the acpmux daemon's share host (ShareHostDevice.swift) alike.
    @MainActor func makeHub(url: URL, identity: DeviceIdentity, bundleID: String, loginKeychain: LoginKeychain,
                            buildSpace: DeviceHubBuildSpace, tokens: @escaping @Sendable () async throws -> String) -> DeviceHub {
        let client = DeviceHubClient(baseURL: url, identity: identity, tokens: DeviceHubAccountToken(tokens), buildSpace: buildSpace)
        return DeviceHub(client: client, socket: DeviceHubSocket(connector: RemotePushConnector(devices: self)),
                         secrets: KeychainRelaySecretStore(bundleIdentifier: bundleID, loginKeychain: loginKeychain), deviceName: MacScreenShareHost.computerName,
                         renewIdentity: { [self] in try blockingIdentity(renew: true) })
    }

    private func makeIdentity(_ answer: [String: Any]) throws -> DeviceIdentity {
        guard let id = (answer["id"] as? String).flatMap(UUID.init(uuidString:)),
              let signing = (answer["signing_key"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let agreement = (answer["agreement_key"] as? String).flatMap({ Data(base64Encoded: $0) }) else {
            throw DeviceHubError.identity("cmux Remote gave no device identity")
        }
        let keys = try RemoteDeviceKeys(signing: P256.Signing.PublicKey(x963Representation: signing),
                                        agreement: P256.KeyAgreement.PublicKey(x963Representation: agreement), devices: self)
        return DeviceIdentity(deviceID: id, keys: keys)
    }

    /// `buildSpace`: the dev build's `dev:<slug>` the device was anchored in, nil for the default space. Nil today:
    /// DeviceHubService uses the worker's device only in the default space, since the pinned cmux Remote (dev) predates
    /// build spaces and ignores the value.
    func anchored(userID: String, hubURL: URL, buildSpace: String? = nil) async {
        var params: [String: Any] = ["user_id": userID, "hub_url": hubURL.absoluteString]
        if let buildSpace { params["build_space"] = buildSpace }
        _ = try? await channel().call("hub.anchored", params)
    }

    func signedOut() async {
        _ = try? await channel().call("hub.signed_out")
    }

    /// This Mac's join consent for Mac Screen, as the worker serves it with the app quit.
    public func consent(enabled: Bool, view: Bool, full: Bool) async {
        _ = try? await channel().call("consent", ["enabled": enabled, "view": view, "full": full])
    }

    /// A synchronous sign or open (DeviceKeyMaterial is synchronous): one blocking round trip on
    /// the request channel, bounded by its read timeout. Never on the main thread: hub requests
    /// sign on the client's actor and ticket signaling on its own tasks.
    func blockingCall(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        if let live = control.withLock({ $0 }), live.isOpen { return try live.blockingCall(method, params) }
        // The worker restarted: reopen the channel (async) and wait for it, bounded; this runs off the main thread.
        // concurrency-allow: the one-shot signal for the bounded reopen wait below (never on the main thread).
        let opened = DispatchSemaphore(value: 0)
        // task-owner: one reopen; the wait below is bounded.
        Task.detached(priority: .userInitiated) { [self] in
            _ = try? await channel()
            opened.signal()
        }
        // concurrency-allow: never on the main thread (see RemoteDeviceKeys); bounded by the channel timeout.
        guard opened.blockingWait(timeout: .now() + RemoteDeviceChannel.timeout) == .success,
              let live = control.withLock({ $0 }), live.isOpen else { throw DeviceHubError.identity("cmux Remote's device channel is closed") }
        return try live.blockingCall(method, params)
    }

    /// Each time the acpmux daemon's share host comes online as its device (`device.watch`): the device id and the hub
    /// user it signed in as, the first at once when it is online already; and when its link stops (the hub dropped the
    /// device), the id it held. Ends with the channel (the daemon stopped, or one without the method), or when the
    /// stream is dropped.
    func events() -> AsyncStream<ShareHostEvent> {
        // Only the newest matters: the device the daemon is online as now, or that it lost.
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            // task-owner: one watch channel; the stream's end cancels it and closes the channel.
            let task = Task.detached(priority: .utility) { [open] in
                defer { continuation.finish() }
                guard let socket = try? await open() else { return }
                let watch = RemoteDeviceChannel(socket: socket)
                defer { watch.close() }
                guard (try? await watch.call("device.watch")) != nil else { return }
                await withTaskCancellationHandler {
                    while let line = await watch.nextPush() {
                        if let event = ShareHostEvent(line: line) { continuation.yield(event) }
                    }
                } onCancel: { watch.close() }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The hub's pushes from the worker's socket, as a socket this app's hub reads.
    func subscribe() async throws -> any DeviceHubSocketConnection {
        let fresh = RemoteDeviceChannel(socket: try await open())
        do {
            _ = try await fresh.call("host.mode", ["mode": "relay-only"])
            _ = try await fresh.call("hub.subscribe")
        } catch {
            fresh.close()
            throw error
        }
        let previous = subscription.withLock { current in
            defer { current = fresh }
            return current
        }
        previous?.close()
        return RemotePushConnection(channel: fresh)
    }
}

/// The worker's keys, used through its channel.
nonisolated struct RemoteDeviceKeys: DeviceKeyMaterial {
    let signing: P256.Signing.PublicKey
    let agreement: P256.KeyAgreement.PublicKey
    let devices: CmuxRemoteDevices

    var signingPublicKey: P256.Signing.PublicKey { signing }
    var agreementPublicKey: P256.KeyAgreement.PublicKey { agreement }

    func signature(for message: Data) throws -> P256.Signing.ECDSASignature {
        let answer = try devices.blockingCall("device.sign", ["message": message.base64EncodedString()])
        guard let raw = (answer["signature"] as? String).flatMap({ Data(base64Encoded: $0) }) else {
            throw DeviceHubError.identity("cmux Remote did not sign")
        }
        return try P256.Signing.ECDSASignature(rawRepresentation: raw)
    }

    func open(_ ciphertext: Data, encapsulatedKey: Data, info: Data) throws -> Data {
        let answer = try devices.blockingCall("device.open", ["ciphertext": ciphertext.base64EncodedString(),
                                                              "encapsulated_key": encapsulatedKey.base64EncodedString(),
                                                              "info": info.base64EncodedString()])
        guard let plain = (answer["plaintext"] as? String).flatMap({ Data(base64Encoded: $0) }) else {
            throw DeviceHubError.identity("cmux Remote did not open the relay secret")
        }
        return plain
    }
}

/// The acpmux daemon's `{"event":"online","id":..,"user_id":..}`: it is online as device `id`, signed in as `userID`.
nonisolated struct ShareHostOnline: Equatable, Sendable {
    let id: String
    let userID: String

    init(id: String, userID: String) {
        self.id = id.lowercased()
        self.userID = userID
    }

    init?(line: String) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              object["event"] as? String == "online", let id = object["id"] as? String, !id.isEmpty,
              let user = object["user_id"] as? String, !user.isEmpty else { return nil }
        self.init(id: id, userID: user)
    }
}

/// What the acpmux daemon's `device.watch` says: it is online as a device (``ShareHostOnline``), or its link stopped
/// (`{"event":"stopped","id":..}`: the hub removed or signed out device `id`, which it no longer lists).
nonisolated enum ShareHostEvent: Equatable, Sendable {
    case online(ShareHostOnline)
    case stopped(id: String)

    init?(line: String) {
        if let online = ShareHostOnline(line: line) {
            self = .online(online)
            return
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              object["event"] as? String == "stopped", let id = object["id"] as? String, !id.isEmpty else { return nil }
        self = .stopped(id: id.lowercased())
    }
}
