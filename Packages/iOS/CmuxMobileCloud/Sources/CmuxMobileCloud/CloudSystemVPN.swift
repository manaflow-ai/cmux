public import Observation

/// Owns a separate enrollment for other apps' access to Cloud private routes.
/// Starts only on a user action. Leaving Cloud or backgrounding cmux does not
/// stop it; changing account/team removes the saved VPN.
@MainActor
@Observable
public final class CloudSystemVPNController {
    public private(set) var phase: CloudSystemVPNPhase = .off
    private let service: any CloudVMServing
    private let identityResolver: CloudDeviceIdentityResolver
    private let manager: any CloudSystemVPNManaging
    private let deviceName: String
    private var scope: String?
    private var hasLoadedScope = false
    private var generation: UInt64 = 0
    private var operation: Task<Void, Never>?

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
            self.acceptStatus(phase)
        }
    }

    /// Called when auth/team changes, including the first signed-in render.
    /// Preferences for another scope are removed before any new connection.
    public func setScope(_ newScope: String?) {
        guard !hasLoadedScope || scope != newScope else { return }
        hasLoadedScope = true
        let previousScope = scope
        scope = newScope
        phase = .disconnecting
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

    public func refresh() async {
        guard let scope, operation == nil else { return }
        enqueue { [self] generation in
            do {
                try await manager.refresh(scope: scope)
                guard self.generation == generation else { return }
                acceptStatus(manager.phase)
            } catch {
                guard self.generation == generation else { return }
                phase = .failed(.configuration)
            }
        }
        await waitForPendingOperation()
    }

    private func acceptStatus(_ status: CloudSystemVPNPhase) {
        // Returning from a declined consent sheet must retain recovery actions.
        if case .failed = phase, status == .off { return }
        phase = status
    }

    /// Explicit opt-in. The OS owns consent and connection status.
    public func enable() {
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
                let identity = try await identityResolver.resolve()
                let enrollment = try await service.enrollTunnel(
                    clientPublicKey: identity.keyPair.publicKey,
                    deviceFingerprint: identity.fingerprint,
                    tunnelPurpose: .browser,
                    deviceName: deviceName + " (system VPN)"
                )
                guard self.generation == generation, self.scope == scope else { return }
                let config = try WireGuardQuickConfig.make(
                    enrollment: enrollment, privateKey: identity.keyPair.privateKey
                )
                try await manager.installAndStart(configuration: config.text, scope: scope)
                guard self.generation == generation else { return }
                phase = manager.phase
            } catch {
                guard self.generation == generation else { return }
                phase = .failed((error as? CloudSystemVPNError) ?? .enrollment)
            }
        }
    }

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

    /// Saves/removals are serialized, including while Apple's consent is open.
    func waitForPendingOperation() async { await operation?.value }

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
