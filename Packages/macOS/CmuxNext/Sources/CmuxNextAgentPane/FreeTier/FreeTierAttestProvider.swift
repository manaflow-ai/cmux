public import CmuxAppAttest
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
    private var line: AcpmuxCheckedLine?
    private var reader: Task<Void, Never>?
    private var reconnect: Task<Void, Never>?
    private var backoff = Backoff(initial: .seconds(2), maximum: .seconds(60))
    private var refused = false
    private let stateContinuation: AsyncStream<FreeTierState>.Continuation

    /// The relay's free-tier state, as it reports it (the Settings caption).
    public nonisolated let states: AsyncStream<FreeTierState>

    /// - Parameter environment: the acpmux this app runs; its relay socket is `<home>/router/router.sock`.
    /// - Parameter attest: App Attest and DeviceCheck.
    /// - Parameter keys: where the free-tier key id lives.
    /// - Parameter clock: spaces reconnects.
    /// - Parameter logger: one line per refusal or failure; never a proof.
    public init(environment: AcpmuxEnvironment, attest: any DeviceAttesting, keys: any AttestKeyStore,
                clock: any Clock<Duration> = ContinuousClock(), logger: Logger) {
        var router = environment
        router.socketPath = environment.home.appendingPathComponent("router", isDirectory: true)
            .appendingPathComponent("router.sock").path
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
    public func start(origin: String, enabled: Bool, managed: Bool) {
        self.origin = origin
        self.enabled = enabled
        self.managed = managed
        refused = false
        connect()
    }

    /// The setting changed: the relay ends a live free lease when it turns off.
    /// - Parameter enabled: `freeModel.enabled`.
    /// - Parameter managed: whether an MDM profile or a team policy sets it.
    public func update(enabled: Bool, managed: Bool) {
        guard enabled != self.enabled || managed != self.managed else { return }
        self.enabled = enabled
        self.managed = managed
        line?.send(Self.encode(["enabled": enabled, "managed": managed]))
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
        let register = Self.encode([
            "op": "attest_provider", "version": 1, "platform": "mac", "origin": origin,
            "enabled": enabled, "managed": managed, "has_key": keys.load() != nil,
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
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
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
                refused = true
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
        guard enabled else { return ["error": "disabled"] }
        guard attest.isSupported else { return ["error": "unsupported"] }
        do {
            switch request["req"] as? String {
            case "attest":
                if request["fresh_key"] as? Bool == true { keys.delete() }
                let keyID: String
                if let known = keys.load() {
                    keyID = known
                } else {
                    keyID = try await attest.generateKey()
                    keys.save(keyID)
                }
                let attestation = try await attest.attestKey(keyID, clientDataHash: hash)
                let token = try await attest.deviceCheckToken()
                return ["key_id": keyID, "attestation": attestation.base64EncodedString(),
                        "device_token": token.base64EncodedString()]
            case "assert":
                guard let keyID = keys.load() else { return ["error": "invalid_key"] }
                let assertion = try await attest.generateAssertion(keyID, clientDataHash: hash)
                return ["key_id": keyID, "assertion": assertion.base64EncodedString()]
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
        } catch {
            return ["error": "failed"]
        }
    }

    private static func encode(_ object: [String: Any]) -> Data {
        ((try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)) + Data([0x0A])
    }
}
