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

    /// The request channel, opened on first use and again after it ends.
    private func channel() async throws -> RemoteDeviceChannel {
        if let live = control.withLock({ $0 }), live.isOpen { return live }
        let fresh = RemoteDeviceChannel(socket: try await open())
        control.withLock { $0 = fresh }
        return fresh
    }

    /// This device's identity from the worker (its keys stay in the worker's Secure Enclave).
    func identity(renew: Bool = false) async throws -> DeviceIdentity {
        let answer = try await channel().call(renew ? "device.renew" : "device.identity")
        guard let id = (answer["id"] as? String).flatMap(UUID.init(uuidString:)),
              let signing = (answer["signing_key"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let agreement = (answer["agreement_key"] as? String).flatMap({ Data(base64Encoded: $0) }) else {
            throw DeviceHubError.identity("cmux Remote gave no device identity")
        }
        let keys = try RemoteDeviceKeys(signing: P256.Signing.PublicKey(x963Representation: signing),
                                        agreement: P256.KeyAgreement.PublicKey(x963Representation: agreement), devices: self)
        return DeviceIdentity(deviceID: id, keys: keys)
    }

    func anchored(userID: String, hubURL: URL) async {
        _ = try? await channel().call("hub.anchored", ["user_id": userID, "hub_url": hubURL.absoluteString])
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
        guard let live = control.withLock({ $0 }), live.isOpen else { throw DeviceHubError.identity("cmux Remote's device channel is closed") }
        return try live.blockingCall(method, params)
    }

    /// The hub's pushes from the worker's socket, as a socket this app's hub reads.
    func subscribe() async throws -> any DeviceHubSocketConnection {
        let fresh = RemoteDeviceChannel(socket: try await open())
        _ = try await fresh.call("hub.subscribe")
        subscription.withLock { $0 = fresh }
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

