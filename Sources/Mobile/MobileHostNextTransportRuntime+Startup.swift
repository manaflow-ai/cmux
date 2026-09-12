#if DEBUG
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxIrohTransport
import CmuxNextTransport
import Foundation
import IrohLib
import Observation
import OSLog

extension MobileHostNextTransportRuntime {
    // MARK: - Startup (cache-first, register-when-ready)

    func start(generation gen: UInt64) async {
        guard await awaitEndpointClose(generation: gen) else { return }
        await startAfterEndpointClose(generation: gen)
    }

    /// Keeps endpoint teardown ahead of authentication and all new binding.
    func awaitEndpointClose(generation gen: UInt64) async -> Bool {
        let previousEndpointClosed = await endpointCloseTask?.value
        guard generation == gen, !Task.isCancelled else { return false }
        if previousEndpointClosed == false {
            // One retry per explicit start, on the same retained endpoint.
            // Do not loop or permit a replacement bind after another failure.
            guard let operation = endpointCloseOperation else { return false }
            let retry = endpointCloseAttempt(operation)
            endpointCloseTask = retry
            let closed = await retry.value
            guard generation == gen, !Task.isCancelled, closed else { return false }
        }
        endpointCloseTask = nil
        endpointCloseOperation = nil
        return true
    }

    private func startAfterEndpointClose(generation gen: UInt64) async {
        let startClock = ContinuousClock.now
        state = "starting"
        readiness = .starting
        MobileHostNextTransportRuntime.logger.notice("host start begin state=starting")
        do {
            // The parallel host is account-bound. Do not bind an endpoint or
            // mint grants while auth is signed out; the auth observer retries
            // after the next authenticated session is published.
            guard await MobileHostService.shared.currentAuthenticatedLocalUserID() != nil else {
                state = "waiting for authenticated account"
                MobileHostNextTransportRuntime.logger.notice(
                    "host start deferred: no authenticated account")
                return
            }
            await grantRevocationTask?.value
            let revokedGrantIDs = try await grantRevocationStore.load()
            // Keys live in the Keychain (one-time migration from the legacy
            // UserDefaults copies); identity is stable per install, separate
            // from the legacy transport's identity (parallel hosts, parallel
            // keys), and the signer persists so previously minted phone
            // grants survive Mac restarts.
            let identity = try await Self.loadOrCreateIdentity()
            let signer = try await Self.loadOrCreateSigner()
            guard generation == gen else { return }
            self.signer = signer
            let revocationStore = grantRevocationStore
            let host = TransportHost(
                verifier: GrantVerifier(serverPublicKeyData: signer.publicKeyData),
                expiryGraceSeconds: Self.grantExpiryGraceSeconds,
                expiryWarningSeconds: 600,
                accountIDProvider: {
                    await MobileHostService.shared.currentAuthenticatedLocalUserID()
                },
                initialRevokedGrantIDs: revokedGrantIDs,
                onGrantRevoked: { id in
                    do { try await revocationStore.revoke([id]) }
                    catch {
                        Self.logger.error("grant revocation persistence failed; restart remains blocked: \(String(describing: error), privacy: .public)")
                    }
                })
            self.host = host

            // Staging credentials via the same self-minting client the
            // phone proved in the lab. Construction reads ~/.secrets, so it
            // runs off the main actor.
            let client = await Task.detached { Self.brokerClient(identity: identity) }.value
            guard generation == gen else { return }
            credentialClient = client
            MobileHostNextTransportRuntime.logger.notice(
                """
                host broker client \(client == nil ? "ABSENT (no dogfood credentials; direct-only)" : "ready", privacy: .public) \
                device=\(String(identity.deviceID.prefix(8)), privacy: .public)
                """)

            // Cache-first: bind IMMEDIATELY with still-valid cached relay
            // credentials (past the reuse margin), or without them. The
            // broker mint is never on the binding path.
            let cached = await Self.loadCachedRelayCredentials()
            guard generation == gen else { return }
            // Cached credentials are endpoint-bound. A regenerated identity
            // must never reuse the previous endpoint's token and publish a
            // relay route that the fleet will silently reject.
            let identityBoundCached = cached.filter {
                IrohSubstrate().tokenEndpointId($0.token) == identity.publicKeyData
            }
            let usable = relayCachePolicy.usable(
                identityBoundCached, now: Int64(Date().timeIntervalSince1970))
            let plan = NextTransportRelayPlan.make(
                hasBrokerClient: client != nil, hasUsableCache: !usable.isEmpty)
            MobileHostNextTransportRuntime.logger.notice(
                """
                host relay plan \(String(describing: plan), privacy: .public) \
                cached=\(cached.count, privacy: .public) \
                usable=\(usable.count, privacy: .public)
                """)

            let relays = usable.map {
                IrohSubstrate.RelayAccess(url: $0.relayUrl, authToken: $0.token)
            }
            let endpoint: Endpoint
            switch plan {
            case .directOnlyDeliberate:
                endpoint = try await IrohSubstrate().endpoint(
                    identity: identity, minimalLoopback: false)
            case .cachedCredential, .awaitFirstMint:
                // awaitFirstMint binds NOW with an empty custom relay map;
                // the first mint inserts into it make-before-break.
                endpoint = try await IrohSubstrate().endpoint(identity: identity, relays: relays)
            }
            guard generation == gen, !Task.isCancelled else {
                try? await endpoint.close()
                return
            }
            self.endpoint = endpoint
            startGrantExpiryLoop(host: host, generation: gen)
            endpointID = HexEncoding().lowercase(endpoint.id().toBytes())
            relayURL = usable.first?.relayUrl
            MobileHostNextTransportRuntime.logger.notice(
                """
                host endpoint bound id=\(String(self.endpointID?.prefix(8) ?? "?"), privacy: .public) \
                relays=\(relays.count, privacy: .public) \
                sockets=\(endpoint.boundSockets().joined(separator: ","), privacy: .public) \
                elapsedMs=\(Self.elapsedMs(since: startClock), privacy: .public)
                """)

            var cachedRelayConfirmed = relays.isEmpty
            if !relays.isEmpty {
                // Keep the uncancellable FFI observation owned until endpoint
                // teardown, but apply the deadline to its cancellable signal.
                let onlineWait = IrohEndpointOnlineWait(endpoint: endpoint)
                endpointOnlineWait = onlineWait
                let cameOnline = await onlineWait.value(
                    timeout: .seconds(NextTransportHostTiming.onlineDeadlineSeconds), sleep: sleep)
                if !cameOnline {
                    // Abort only the unconfirmed relay legs. Keeping the
                    // endpoint alive preserves direct LAN candidates while a
                    // later broker mint repairs the relay map.
                    for relay in relays {
                        _ = try? await endpoint.removeRelay(url: relay.url)
                    }
                } else { endpointOnlineWait = nil }
                guard generation == gen else { return }
                cachedRelayConfirmed = cameOnline
                if !cameOnline {
                    // Direct paths remain usable, but an unconfirmed cached
                    // relay must never be published as a live route. A broker
                    // client will mint and insert a replacement below.
                    relayURL = nil
                    refreshStateDescription()
                }
                MobileHostNextTransportRuntime.logger.notice(
                    """
                    host relay online \(cameOnline ? "confirmed" : "NOT confirmed within deadline (continuing; background mint will rotate)", privacy: .public) \
                    relay=\(self.relayURL ?? "none", privacy: .public)
                    """)
            }

            startAcceptLoop(endpoint: endpoint, host: host, generation: gen)
            setReadiness(.bound, generation: gen)

            switch plan {
            case .directOnlyDeliberate:
                // Deliberately direct-only (no broker client): the relay leg
                // is skipped, not pending.
                setReadiness(.relayAttached, generation: gen)
                publishIfReady(generation: gen)
            case .cachedCredential:
                if cachedRelayConfirmed {
                    // The relay handshake succeeded, so this cached route is
                    // safe to publish. Without a broker client, a bounded
                    // expiry watcher withdraws it when the token ends.
                    setReadiness(.relayAttached, generation: gen)
                    publishIfReady(generation: gen)
                }
                if let client {
                    startCredentialLoop(
                        endpoint: endpoint, client: client,
                        initialEntries: cachedRelayConfirmed ? usable : [], generation: gen)
                } else if cachedRelayConfirmed {
                    startCachedCredentialExpiryWatcher(
                        endpoint: endpoint, entries: usable, generation: gen)
                } else {
                    // No refresh authority and no confirmed relay: publish a
                    // direct-only route after the endpoint has bound.
                    relayURL = nil
                    setReadiness(.relayAttached, generation: gen)
                    publishIfReady(generation: gen)
                }
            case .awaitFirstMint:
                // Relay attachment (and publication) wait on the first mint;
                // binding and the accept loop already did not.
                if let client {
                    startCredentialLoop(
                        endpoint: endpoint, client: client,
                        initialEntries: [], generation: gen)
                }
            }
            MobileHostNextTransportRuntime.logger.notice(
                """
                next-transport host up: \(self.endpointID ?? "?", privacy: .public) \
                state=\(self.state, privacy: .public) \
                readiness=\(self.readiness.description, privacy: .public) \
                elapsedMs=\(Self.elapsedMs(since: startClock), privacy: .public)
                """)
        } catch {
            guard generation == gen else { return }
            state = "failed: \(error)"
            MobileHostNextTransportRuntime.logger.error(
                """
                next-transport start failed: \(String(describing: error), privacy: .public) \
                elapsedMs=\(Self.elapsedMs(since: startClock), privacy: .public)
                """)
        }
    }

}
#endif
