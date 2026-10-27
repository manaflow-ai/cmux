public import CmuxAppAttest
import CmuxNextCompat
import CmuxNextWakeups
public import Foundation
public import os

/// The app's half of the free tier (cx-ds09i): an App Attest provider for the
/// local model relay (cmux-tui crate cmux-coderouter, `free_tier.rs`).
///
/// The relay owns the lease: it asks the cmux API for challenges, sends the
/// tokens and renews them. The app only proves the device. It keeps one
/// connection to the relay's admin socket (`attest_provider`), checked like
/// every acpmux connection (``AcpmuxCheckedLine``: the peer runs this app's
/// own acpmux, Team-signed by this app's team), and answers two requests on it:
///
/// - `attest`: attests the free-tier key over the relay's 32-byte hash, with a
///   DeviceCheck token; `fresh_key` first forgets the old key id;
/// - `assert`: an assertion by that key over the hash.
///
/// Only the purpose `cmux.free-tier.v1` with a 32-byte hash is answered; the
/// app signs a hash, never a token. One request at a time, in order (the
/// assertion counter must grow). The only key is the free-tier key, whose id
/// lives in its own ``AttestKeyStore`` item.
///
/// ```swift
/// let provider = FreeTierAttestProvider(environment: acpmux, attest: AppleDeviceAttest(service: .shared, device: .current),
///                                       keys: KeychainAttestKeyStore(service: "...", account: "key"), logger: logger)
/// await provider.start(origin: "https://cloud-api.cmux.dev", enabled: true, managed: false)
/// ```
public actor FreeTierAttestProvider {
    /// The one purpose the app signs for.
    public static let purpose = "cmux.free-tier.v1"

    private let routerEnvironment: AcpmuxEnvironment
    private let attest: any DeviceAttesting
    private let keys: any AttestKeyStore
    private let clock: any Clock<Duration>
    private let logger: Logger
    private var origin: String?
    private var enabled = false
    private var managed = false
    private var signedIn = false
    private var line: AcpmuxCheckedLine?
    private var reader: Task<Void, Never>?
    private var reconnect: Task<Void, Never>?
    private var backoff = Backoff(initial: .seconds(2), maximum: .seconds(60))
    private var refused = false
    /// Counts connections: a proof that finishes after a reconnect saves nothing.
    private var generation = 0
    /// A key id store error (for example a denied Keychain access) stops all proofs until the
    /// next launch or a settings change, so the store is not asked again (no repeated prompt).
    private var storeFailed = false
    private let stateContinuation: AsyncStream<FreeTierState>.Continuation

    /// The relay's free-tier state, as it reports it (the Settings caption).
    public nonisolated let states: AsyncStream<FreeTierState>

    /// - Parameter environment: the acpmux this app runs; its relay socket is
    ///   ``LocalRouterClient/socketPath(acpmuxHome:uid:)`` (`<home>/router/router.sock`, or a short path for a long home).
    /// - Parameter attest: App Attest and DeviceCheck.
    /// - Parameter keys: where the free-tier key id lives.
    /// - Parameter clock: spaces reconnects.
    /// - Parameter logger: one line per refusal or failure; never a proof.
    public init(environment: AcpmuxEnvironment, attest: any DeviceAttesting, keys: any AttestKeyStore,
                clock: any Clock<Duration> = ContinuousClock(), logger: Logger) {
        var router = environment
        router.socketPath = LocalRouterClient.socketPath(acpmuxHome: environment.home)
        routerEnvironment = router
        self.attest = attest
        self.keys = keys
        self.clock = clock
        self.logger = logger
        (states, stateContinuation) = AsyncStream.makeStream(of: FreeTierState.self, bufferingPolicy: .bufferingNewest(1))
    }

    /// Connects to the relay and registers for the cmux API at `origin`.
    /// - Parameter origin: the cmux API origin the relay sends the free token to.
    /// - Parameter enabled: `freeModel.enabled`.
    /// - Parameter managed: whether an MDM profile or a team policy sets it.
    /// - Parameter signedIn: an account is signed in (the relay then never takes a free lease).
    public func start(origin: String, enabled: Bool, managed: Bool, signedIn: Bool) {
        self.origin = origin
        self.enabled = enabled
        self.managed = managed
        self.signedIn = signedIn
        refused = false
        storeFailed = false
        connect()
    }

    /// The setting or the sign-in changed: the relay ends a live free lease
    /// when the setting turns off or an account signs in.
    /// - Parameter enabled: `freeModel.enabled`.
    /// - Parameter managed: whether an MDM profile or a team policy sets it.
    /// - Parameter signedIn: an account is signed in.
    public func update(enabled: Bool, managed: Bool, signedIn: Bool) {
        guard enabled != self.enabled || managed != self.managed || signedIn != self.signedIn else { return }
        self.enabled = enabled
        self.managed = managed
        self.signedIn = signedIn
        storeFailed = false
        line?.send(Self.encode(["enabled": enabled, "managed": managed, "signed_in": signedIn]))
    }

    /// Ends the connection; the relay drops its free token at once.
    public func stop() {
        origin = nil
        reconnect?.cancel()
        reconnect = nil
        disconnect()
    }

    private func connect() {
        disconnect()
        guard let origin else { return }
        generation += 1
        let register = Self.encode([
            "op": "attest_provider", "version": 1, "platform": "mac", "origin": origin,
            // No Keychain read where App Attest cannot work (no prompt in an ad-hoc DEV build);
            // a read error says no key here, and the attest request then refuses (no new key).
            "enabled": enabled, "managed": managed,
            "has_key": attest.isSupported && ((try? keys.load()) ?? nil) != nil, "signed_in": signedIn,
        ])
        let (lines, sink) = AsyncStream.makeStream(of: Data?.self, bufferingPolicy: .bufferingNewest(64))
        let connection = AcpmuxCheckedLine(environment: routerEnvironment)
        line = connection
        // task-owner: reads this connection's lines in order; cancelled by disconnect(), ends at the connection's end
        reader = Task { [weak self] in
            for await message in lines {
                guard let self else { return }
                guard let message else { return await self.closed(connection) }
                await self.received(message, on: connection)
            }
        }
        connection.start(send: register, onLine: { sink.yield($0) }, onClose: {
            sink.yield(nil)
            sink.finish()
        })
    }

    private func disconnect() {
        reader?.cancel()
        reader = nil
        line?.cancel()
        line = nil
    }

    private func closed(_ connection: AcpmuxCheckedLine) {
        guard connection === line else { return }
        line = nil
        reader = nil
        stateContinuation.yield(.off)
        guard origin != nil, !refused else { return }
        reconnect?.cancel()
        var backoff = backoff
        let clock = clock
        // task-owner: one spaced reconnect after the relay connection ended (the daemon starts a new relay); cancelled by stop()
        reconnect = Task { [weak self] in
            // wakeup-allow: one Backoff wait before reconnecting to a relay that ended
            do { try await backoff.wait(owner: "FreeTierAttestProvider.reconnect", clock: clock) } catch { return }  // concurrency-allow: Backoff.wait is an async clock sleep in this actor's task, never a blocking wait
            await self?.reconnected(backoff)
        }
    }

    private func reconnected(_ backoff: Backoff) {
        self.backoff = backoff
        reconnect = nil
        connect()
    }

    private func received(_ data: Data, on connection: AcpmuxCheckedLine) async {
        guard connection === line,
              let message = (try? JSONSerialization.blockingJSONObject(with: data)) as? [String: Any] else { return }
        if message["provider"] as? Bool == true {
            backoff.reset()
            return
        }
        if message["event"] as? String == "free_state" {
            if let raw = message["state"] as? String, let state = FreeTierState(rawValue: raw) {
                stateContinuation.yield(state)
            }
            return
        }
        guard let id = message["id"] as? NSNumber else {
            if let error = message["error"] as? String {
                // The relay refused this provider (origin or peer): no retry until the next start.
                // Any other error is a relay too old for attest_provider: the daemon replaces it,
                // so the connection's end reconnects as usual.
                if error == "provider origin refused" || error == "provider refused" { refused = true }
                logger.error("free tier: the local relay refused the provider: \(error, privacy: .public)")
            }
            return
        }
        let reply = await answer(message)
        guard connection === line else { return }
        var out = reply
        out["id"] = id
        connection.send(Self.encode(out))
    }

    /// The reply to one relay request (its fields, without the id).
    private func answer(_ request: [String: Any]) async -> [String: Any] {
        guard request["purpose"] as? String == Self.purpose,
              let encoded = request["client_data_hash"] as? String,
              let hash = Data(base64Encoded: encoded), hash.count == 32 else { return ["error": "refused"] }
        guard enabled, !signedIn else { return ["error": "disabled"] }
        // The store refused once: say so again without asking it (the relay then stays store_failed).
        guard !storeFailed else { return ["error": "store_failed"] }
        guard attest.isSupported else { return ["error": "unsupported"] }
        do {
            switch request["req"] as? String {
            case "attest":
                let started = generation
                if request["fresh_key"] as? Bool == true { try keys.delete() }
                let keyID: String
                // A store error throws: no new key is made when the old id cannot be read.
                if let known = try keys.load() {
                    keyID = known
                } else {
                    keyID = try await attest.generateKey()
                    // A reconnect while the key was made: a newer request owns the key id now.
                    guard generation == started else { return ["error": "failed"] }
                    // Saved before the attestation: a key whose id cannot be kept is never attested.
                    try keys.save(keyID)
                }
                let attestation = try await attest.attestKey(keyID, clientDataHash: hash)
                let token = try await attest.deviceCheckToken()
                return ["key_id": keyID, "attestation": Self.base64URL(attestation),
                        "device_token": token.base64EncodedString()]
            case "assert":
                guard let keyID = try keys.load() else { return ["error": "invalid_key"] }
                let assertion = try await attest.generateAssertion(keyID, clientDataHash: hash)
                return ["key_id": keyID, "assertion": Self.base64URL(assertion)]
            default:
                return ["error": "refused"]
            }
        } catch let error as DeviceAttestError {
            switch error {
            case .unsupported: return ["error": "unsupported"]
            case .invalidKey: return ["error": "invalid_key"]
            case .failed:
                logger.info("free tier: an App Attest call failed")
                return ["error": "failed"]
            }
        } catch let error as AttestKeyStoreError where error.isDamagedItem {
            // A stored id that does not decode: the relay asks for one fresh key (fresh_key deletes it).
            logger.error("free tier: the stored App Attest key id is damaged; asking for a fresh key")
            return ["error": "invalid_key"]
        } catch let error as AttestKeyStoreError {
            // The key id cannot be read or kept (a denied Keychain access): no new key, no proof,
            // and no further store access until the next launch or a settings change.
            storeFailed = true
            logger.error("free tier: the App Attest key id store failed (status \(error.status, privacy: .public)); no new key, proofs paused")
            return ["error": "store_failed"]
        } catch {
            return ["error": "failed"]
        }
    }

    /// Unpadded base64url: the cmux API's token route decodes proofs only in that form
    /// (the DeviceCheck token stays standard base64, as Apple expects it).
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func encode(_ object: [String: Any]) -> Data {
        ((try? CheckedJSON().data(object)) ?? Data("{}".utf8)) + Data([0x0A])
    }
}
