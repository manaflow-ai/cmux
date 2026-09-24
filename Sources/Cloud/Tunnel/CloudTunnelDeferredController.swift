import Foundation

/// A ``CloudTunnelControlling`` that builds the real controller on the first
/// ``install(_:onNeedsUserApproval:)`` and behaves as "no configuration"
/// until then.
///
/// ``NetworkExtensionTunnelController`` reads NetworkExtension preferences the
/// moment it exists. On a Mac that never saved a VPN configuration there is
/// nothing to read, so the coordinator gets this stand-in instead: the status
/// is `.invalid`, stop, remove, and termination are no-ops, and link
/// subscribers are attached to the real controller the moment it is built.
/// Only a start the coordinator admitted (``CloudActivationPolicy``) reaches
/// `install`, so a user who never opted into Cloud never touches
/// NetworkExtension at all.
///
/// Main-actor isolated like the controller it fronts, so
/// ``stopForTermination()`` can read the built controller synchronously on the
/// main thread.
@MainActor
final class CloudTunnelDeferredController: CloudTunnelControlling {
    private let makeController: @MainActor () -> any CloudTunnelControlling
    private var controller: (any CloudTunnelControlling)?
    /// Link subscribers that arrived before the controller existed.
    private var pendingSubscribers: [UUID: AsyncStream<CloudTunnelLinkStatus>.Continuation] = [:]
    /// Subscribers that went away before their attach ran; attach skips them.
    private var detachedBeforeAttach: Set<UUID> = []
    private var forwarders: [UUID: Task<Void, Never>] = [:]

    init(makeController: @escaping @MainActor () -> any CloudTunnelControlling) {
        self.makeController = makeController
    }

    deinit {
        for forwarder in forwarders.values { forwarder.cancel() }
    }

    nonisolated var statusUpdates: AsyncStream<CloudTunnelLinkStatus> {
        AsyncStream { continuation in
            let id = UUID()
            Task { @MainActor [weak self] in
                self?.attach(continuation, id: id)
            }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.detach(id) }
            }
        }
    }

    func currentStatus() async -> CloudTunnelLinkStatus {
        guard let controller else { return .invalid }
        return await controller.currentStatus()
    }

    func install(
        _ configuration: CloudTunnelProviderConfiguration,
        onNeedsUserApproval: @escaping @Sendable () -> Void
    ) async throws {
        try await materialize().install(configuration, onNeedsUserApproval: onNeedsUserApproval)
    }

    func start() async throws {
        guard let controller else { throw CloudTunnelError.configurationNotInstalled }
        try await controller.start()
    }

    func stop() async throws {
        guard let controller else { return }
        try await controller.stop()
    }

    func remove() async throws {
        guard let controller else { return }
        try await controller.remove()
    }

    nonisolated func stopForTermination() {
        MainActor.assumeIsolated {
            controller?.stopForTermination()
        }
    }

    private func materialize() -> any CloudTunnelControlling {
        if let controller { return controller }
        let built = makeController()
        controller = built
        // Subscribe synchronously, before the caller's install returns, so no
        // status the real controller reports during this start is missed.
        let waiting = pendingSubscribers
        pendingSubscribers.removeAll()
        for (id, continuation) in waiting {
            forward(built.statusUpdates, to: continuation, id: id)
        }
        return built
    }

    private func attach(_ continuation: AsyncStream<CloudTunnelLinkStatus>.Continuation, id: UUID) {
        if detachedBeforeAttach.remove(id) != nil { return }
        if let controller {
            forward(controller.statusUpdates, to: continuation, id: id)
        } else {
            pendingSubscribers[id] = continuation
        }
    }

    private func detach(_ id: UUID) {
        if pendingSubscribers.removeValue(forKey: id) == nil, forwarders[id] == nil {
            detachedBeforeAttach.insert(id)
        }
        forwarders.removeValue(forKey: id)?.cancel()
    }

    private func forward(
        _ updates: AsyncStream<CloudTunnelLinkStatus>,
        to continuation: AsyncStream<CloudTunnelLinkStatus>.Continuation,
        id: UUID
    ) {
        forwarders[id] = Task {
            for await status in updates {
                continuation.yield(status)
            }
            continuation.finish()
        }
    }
}
