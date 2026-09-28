public import Observation

/// Owns the optional system VPN that lets Safari and other apps reach Cloud
/// machines' private addresses.
///
/// Separate from ``CloudSessionController``'s in-process tunnel in every
/// way: it is its own WireGuard peer (enrolled under the `browser` purpose
/// with its own key, so the two never contend for one peer), it runs in the
/// packet tunnel extension that iOS owns, and it starts only when the user
/// turns it on. Leaving the Cloud tab or backgrounding the app does not stop
/// it. Signing out, or switching to another account, removes it.
///
/// The key is minted on each enable and stored only inside the saved
/// configuration, so it never touches the terminal tunnel's identity item.
@MainActor
@Observable
public final class CloudSystemVPNController {
    /// The VPN's state as the user sees it.
    public private(set) var phase: CloudSystemVPNPhase = .off

    private let service: any CloudVMServing
    private let identityResolver: CloudDeviceIdentityResolver
    private let manager: any CloudSystemVPNManaging
    private let deviceName: String
    private let routePolicy = CloudVPNRoutePolicy()
    private var scope: String?
    private var hasLoadedScope = false
    private var generation: UInt64 = 0
    private var operation: Task<Void, Never>?

    /// - Parameters:
    ///   - service: The `/api/vm` client, for enrollment.
    ///   - identityStore: The device identity store; only its fingerprint is
    ///     used, so the VPN peer is filed under the same device as the
    ///     terminal tunnel.
    ///   - manager: The platform VPN boundary.
    ///   - deviceName: This phone's name, sent on enrollment.
    public init(
        service: any CloudVMServing,
        identityStore: any CloudDeviceIdentityStoring,
        manager: any CloudSystemVPNManaging,
        deviceName: String
    ) {
        self.service = service
        self.identityResolver = CloudDeviceIdentityResolver(store: identityStore)
        self.manager = manager
        self.deviceName = deviceName
        manager.onPhaseChange = { [weak self] phase in
            guard let self, self.scope != nil, self.operation == nil else { return }
            self.accept(phase)
        }
    }

    /// Whether this device can run the VPN at all.
    public var isAvailable: Bool { manager.isAvailable }

    /// Binds the VPN to an account scope, or to none when signed out.
    ///
    /// A VPN saved under another scope is removed before anything else, so
    /// one account's routes never survive into another's session.
    public func setScope(_ newScope: String?) {
        guard !hasLoadedScope || scope != newScope else { return }
        hasLoadedScope = true
        let previousScope = scope
        scope = newScope
        // A device that cannot run the VPN never saved one, so there is
        // nothing to load or remove.
        guard manager.isAvailable else { return }
        enqueue { [self] generation in
            do {
                if previousScope != nil || newScope == nil {
                    try await manager.stop(removeConfiguration: true)
                }
                guard self.generation == generation else { return }
                if let newScope { try await manager.refresh(scope: newScope) }
                guard self.generation == generation else { return }
                phase = manager.phase
            } catch {
                guard self.generation == generation else { return }
                phase = .failed(.configuration)
            }
        }
    }

    /// Re-reads the live status, for example when the app returns to the
    /// foreground after the user changed the VPN in Settings.
    public func refresh() async {
        guard manager.isAvailable, let scope, operation == nil else { return }
        enqueue { [self] generation in
            do {
                try await manager.refresh(scope: scope)
                guard self.generation == generation else { return }
                accept(manager.phase)
            } catch {
                guard self.generation == generation else { return }
                phase = .failed(.configuration)
            }
        }
        await waitForPendingOperation()
    }

    /// The user turned the VPN on. iOS owns consent and the connection.
    public func enable() {
        guard manager.isAvailable else {
            phase = .failed(.unavailable)
            return
        }
        guard let scope else {
            phase = .failed(.enrollment)
            return
        }
        switch phase {
        case .preparing, .connecting, .connected, .disconnecting: return
        case .off, .failed: break
        }
        phase = .preparing
        enqueue { [self] generation in
            do {
                let identity: CloudDeviceIdentity
                let enrollment: CloudTunnelEnrollment
                let keyPair = WireGuardKeyPair()
                do {
                    identity = try await identityResolver.resolve()
                    enrollment = try await service.enrollTunnel(
                        clientPublicKey: keyPair.publicKey,
                        deviceFingerprint: identity.fingerprint,
                        tunnelPurpose: .browser,
                        deviceName: deviceName
                    )
                } catch {
                    throw CloudSystemVPNError.enrollment
                }
                guard self.generation == generation, self.scope == scope else { return }
                guard permitsOnlyPrivateRoutes(enrollment) else { throw CloudSystemVPNError.configuration }
                let configuration: WireGuardQuickConfig
                do {
                    configuration = try WireGuardQuickConfig.make(
                        enrollment: enrollment,
                        privateKey: keyPair.privateKey
                    )
                } catch {
                    throw CloudSystemVPNError.configuration
                }
                try await manager.installAndStart(configuration: configuration.text, scope: scope)
                guard self.generation == generation else { return }
                phase = manager.phase
            } catch {
                guard self.generation == generation else { return }
                phase = .failed((error as? CloudSystemVPNError) ?? .configuration)
            }
        }
    }

    /// The user turned the VPN off. The configuration stays saved so iOS
    /// Settings can still show it; signing out removes it.
    public func disable() {
        phase = .disconnecting
        enqueue { [self] generation in
            do {
                try await manager.stop(removeConfiguration: false)
                guard self.generation == generation else { return }
                phase = manager.phase
            } catch {
                guard self.generation == generation else { return }
                phase = .failed(.configuration)
            }
        }
    }

    /// Waits for queued saves and removals. Operations run one at a time,
    /// including while the iOS consent prompt is open.
    public func waitForPendingOperation() async { await operation?.value }

    private func accept(_ status: CloudSystemVPNPhase) {
        // A declined consent prompt reports `.off` right after the failure;
        // keep the failure so its recovery actions stay visible.
        if case .failed = phase, status == .off { return }
        phase = status
    }

    /// The routes and interface addresses an enrollment would install must
    /// all be private. An enrollment with no routes routes nothing.
    private func permitsOnlyPrivateRoutes(_ enrollment: CloudTunnelEnrollment) -> Bool {
        guard !enrollment.routes.isEmpty else { return false }
        var cidrs = enrollment.routes
        if let v4 = enrollment.addressV4 { cidrs.append(v4.contains("/") ? v4 : v4 + "/32") }
        if let v6 = enrollment.addressV6 { cidrs.append(v6.contains("/") ? v6 : v6 + "/128") }
        return cidrs.allSatisfy(routePolicy.permits)
    }

    private func enqueue(_ action: @escaping @MainActor (UInt64) async -> Void) {
        generation &+= 1
        let generation = generation
        let previous = operation
        operation = Task { [weak self] in
            await previous?.value
            guard let self, self.generation == generation else { return }
            await action(generation)
            if self.generation == generation { self.operation = nil }
        }
    }
}
