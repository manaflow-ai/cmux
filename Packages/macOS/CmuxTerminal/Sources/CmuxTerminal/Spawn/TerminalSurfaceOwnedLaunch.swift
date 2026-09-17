internal import Foundation

/// A resolved launch and the resources that must remain valid for its process.
public struct TerminalSurfaceOwnedLaunch: Sendable {
    /// The immutable process launch request.
    public let resolvedLaunch: TerminalSurfaceResolvedLaunch
    private let commandShimLeaseHandoff: TerminalSurfaceCommandShimLeaseHandoff?

    /// Creates a launch that owns an optional command-shim resource lease.
    public init(
        resolvedLaunch: TerminalSurfaceResolvedLaunch,
        commandShimLease: TerminalSurfaceAgentCommandShimLease?
    ) {
        self.resolvedLaunch = resolvedLaunch
        commandShimLeaseHandoff = commandShimLease.map {
            TerminalSurfaceCommandShimLeaseHandoff(
                lease: $0,
                releasesUnacceptedLease: true
            )
        }
    }

    init(
        resolvedLaunch: TerminalSurfaceResolvedLaunch,
        borrowingCommandShimLease commandShimLease: TerminalSurfaceAgentCommandShimLease?
    ) {
        self.resolvedLaunch = resolvedLaunch
        commandShimLeaseHandoff = commandShimLease.map {
            TerminalSurfaceCommandShimLeaseHandoff(
                lease: $0,
                releasesUnacceptedLease: false
            )
        }
    }

    init(
        resolvedLaunch: TerminalSurfaceResolvedLaunch,
        provisionalCommandShimLease: TerminalSurfaceAgentCommandShimLease,
        cleanupUnacceptedLease:
            @escaping @Sendable (TerminalSurfaceAgentCommandShimLease) async -> Void
    ) {
        self.resolvedLaunch = resolvedLaunch
        commandShimLeaseHandoff = TerminalSurfaceCommandShimLeaseHandoff(
            lease: provisionalCommandShimLease,
            releasesUnacceptedLease: true,
            cleanupUnacceptedLease: cleanupUnacceptedLease
        )
    }

    /// Transfers the optional command-shim lease to the canonical terminal owner.
    ///
    /// A newly installed lease is released automatically if the caller drops
    /// this launch without accepting it. A reused lease remains owned by its
    /// existing canonical terminal.
    public func takeCommandShimLease() -> TerminalSurfaceAgentCommandShimLease? {
        commandShimLeaseHandoff?.take()
    }
}

private final class TerminalSurfaceCommandShimLeaseHandoff: @unchecked Sendable {
    private let lock = NSLock()
    private var lease: TerminalSurfaceAgentCommandShimLease?
    private let releasesUnacceptedLease: Bool
    private let cleanupUnacceptedLease:
        (@Sendable (TerminalSurfaceAgentCommandShimLease) async -> Void)?

    init(
        lease: TerminalSurfaceAgentCommandShimLease,
        releasesUnacceptedLease: Bool,
        cleanupUnacceptedLease:
            (@Sendable (TerminalSurfaceAgentCommandShimLease) async -> Void)? = nil
    ) {
        self.lease = lease
        self.releasesUnacceptedLease = releasesUnacceptedLease
        self.cleanupUnacceptedLease = cleanupUnacceptedLease
    }

    func take() -> TerminalSurfaceAgentCommandShimLease? {
        lock.withLock {
            defer { lease = nil }
            return lease
        }
    }

    deinit {
        guard releasesUnacceptedLease,
              let lease = lock.withLock({
                  defer { self.lease = nil }
                  return self.lease
              }) else { return }
        let cleanupUnacceptedLease = cleanupUnacceptedLease
        Task.detached(priority: .utility) {
            if let cleanupUnacceptedLease {
                await cleanupUnacceptedLease(lease)
            } else {
                _ = await lease.release()
            }
        }
    }
}
