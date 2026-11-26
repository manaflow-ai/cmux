public import Foundation

public protocol CmxIrohLANClock: Sendable {
    func now() -> Date
    func sleep(for interval: TimeInterval) async throws
}

public struct CmxIrohLANSystemClock: CmxIrohLANClock {
    public init() {}

    public func now() -> Date { Date() }

    public func sleep(for interval: TimeInterval) async throws {
        guard interval.isFinite, interval > 0 else { return }
        let milliseconds = Int64(min(interval, 10 * 60) * 1_000)
        try await ContinuousClock().sleep(for: .milliseconds(milliseconds))
    }
}

public enum CmxIrohLANHostPublisherState: Equatable, Sendable {
    case inactive
    case active
    case unavailable
    case policyDenied
}

/// Owns rotation and replacement of one host's account-private advertisements.
public actor CmxIrohLANHostPublisher {
    public typealias DirectAddressProvider = @Sendable () async -> [String]

    private struct Context: Sendable {
        let rendezvous: CmxIrohLANRendezvous
        let binding: CmxIrohBrokerBindingMetadata
        let directAddresses: DirectAddressProvider
    }

    private let publisher: any CmxIrohBonjourPublishing
    private let interfaces: any CmxIrohLANInterfaceSnapshotProviding
    private let builder: CmxIrohLANAdvertisementBuilder
    private let clock: any CmxIrohLANClock
    private var context: Context?
    private var revision: UInt64 = 0
    private var rotationTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var state: CmxIrohLANHostPublisherState = .inactive

    public init(
        publisher: any CmxIrohBonjourPublishing = CmxIrohSystemBonjourPublisher(),
        interfaces: any CmxIrohLANInterfaceSnapshotProviding = CmxIrohSystemLANInterfaceSnapshotProvider(),
        builder: CmxIrohLANAdvertisementBuilder = CmxIrohLANAdvertisementBuilder(),
        clock: any CmxIrohLANClock = CmxIrohLANSystemClock()
    ) {
        self.publisher = publisher
        self.interfaces = interfaces
        self.builder = builder
        self.clock = clock
    }

    public func snapshot() -> CmxIrohLANHostPublisherState { state }

    public func activate(
        rendezvous: CmxIrohLANRendezvous,
        binding: CmxIrohBrokerBindingMetadata,
        directAddresses: @escaping DirectAddressProvider
    ) async {
        revision &+= 1
        let currentRevision = revision
        rotationTask?.cancel()
        context = Context(
            rendezvous: rendezvous,
            binding: binding,
            directAddresses: directAddresses
        )
        startEventObservationIfNeeded()
        await refresh(revision: currentRevision)
        guard revision == currentRevision, state != .policyDenied else { return }
        rotationTask = Task { [weak self] in
            await self?.rotate(revision: currentRevision)
        }
    }

    /// Re-reads endpoint and interface addresses after a network change.
    public func refresh() async {
        await refresh(revision: revision)
    }

    /// Retries a policy-blocked publication after the user may have changed
    /// Local Network permission. A stopped or inactive listener stays inert.
    public func permissionMayHaveChanged() async {
        guard state == .policyDenied, context != nil else { return }
        let currentRevision = revision
        state = .unavailable
        startEventObservationIfNeeded()
        await refresh(revision: currentRevision)
        guard revision == currentRevision,
              state != .policyDenied,
              context != nil else { return }
        rotationTask?.cancel()
        rotationTask = Task { [weak self] in
            await self?.rotate(revision: currentRevision)
        }
    }

    public func stop() async {
        revision &+= 1
        context = nil
        rotationTask?.cancel()
        rotationTask = nil
        eventTask?.cancel()
        eventTask = nil
        await publisher.stop()
        state = .inactive
    }

    private func rotate(revision expectedRevision: UInt64) async {
        while expectedRevision == revision, !Task.isCancelled {
            let now = clock.now()
            guard let epoch = try? CmxIrohLANRendezvousAliasGenerator.epoch(for: now) else {
                state = .unavailable
                return
            }
            let nextEpoch = Date(
                timeIntervalSince1970: (TimeInterval(epoch) + 1)
                    * CmxIrohLANRendezvousAliasGenerator.rotationInterval
            )
            do {
                try await clock.sleep(for: max(0.001, nextEpoch.timeIntervalSince(now)))
                try Task.checkCancellation()
            } catch {
                return
            }
            await refresh(revision: expectedRevision)
        }
    }

    private func refresh(revision expectedRevision: UInt64) async {
        guard expectedRevision == revision,
              state != .policyDenied,
              let context else { return }
        let directAddresses = await context.directAddresses()
        guard expectedRevision == revision, !Task.isCancelled else { return }
        do {
            let advertisements = try builder.advertisements(
                rendezvous: context.rendezvous,
                binding: context.binding,
                directAddresses: directAddresses,
                interfaces: try interfaces.interfaceAddresses(),
                at: clock.now()
            )
            try await publisher.replace(with: advertisements)
            guard expectedRevision == revision else { return }
            state = advertisements.isEmpty ? .unavailable : .active
        } catch CmxIrohLANDiscoveryError.policyDenied {
            state = .policyDenied
            rotationTask?.cancel()
            rotationTask = nil
        } catch is CancellationError {
            return
        } catch {
            if expectedRevision == revision { state = .unavailable }
        }
    }

    private func startEventObservationIfNeeded() {
        guard eventTask == nil else { return }
        eventTask = Task { [weak self, publisher] in
            let events = await publisher.events()
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.handle(event)
            }
        }
    }

    private func handle(_ event: CmxIrohBonjourPublisherEvent) {
        guard context != nil else { return }
        switch event {
        case .registered:
            break
        case .policyDenied:
            state = .policyDenied
            rotationTask?.cancel()
            rotationTask = nil
        case .failed:
            if state != .policyDenied { state = .unavailable }
        }
    }
}
