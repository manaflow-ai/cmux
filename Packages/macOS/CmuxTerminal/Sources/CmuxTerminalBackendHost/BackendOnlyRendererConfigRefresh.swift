internal import CmuxTerminalBackend

typealias BackendOnlyRendererConfigIdentity = BackendRendererConfigIdentity

struct BackendOnlyRendererConfigFloor: Equatable, Sendable {
    private(set) var identity: BackendOnlyRendererConfigIdentity?

    mutating func record(
        _ invalidation: BackendRendererConfigInvalidated
    ) throws -> Bool {
        let invalidated = BackendOnlyRendererConfigIdentity(
            revision: invalidation.revision,
            digest: invalidation.digest
        )
        guard let identity else {
            self.identity = invalidated
            return true
        }
        if identity.revision > invalidated.revision {
            return false
        }
        if identity.revision == invalidated.revision {
            guard identity.digest == invalidated.digest else {
                throw BackendOnlyRendererConfigRefreshError.inconsistentRevision
            }
            return false
        }
        self.identity = invalidated
        return true
    }

    func satisfies(_ candidate: BackendOnlyRendererConfigIdentity) throws -> Bool {
        guard let identity else { return true }
        if candidate.revision < identity.revision {
            return false
        }
        if candidate.revision == identity.revision,
           candidate.digest != identity.digest {
            throw BackendOnlyRendererConfigRefreshError.inconsistentRevision
        }
        return true
    }

    mutating func accept(_ candidate: BackendOnlyRendererConfigIdentity) throws {
        guard try satisfies(candidate) else {
            throw BackendOnlyRendererConfigRefreshError.staleReceipt
        }
        if let identity {
            if candidate.revision > identity.revision {
                self.identity = candidate
            }
        } else {
            self.identity = candidate
        }
    }
}

enum BackendOnlyRendererConfigRefreshOutcome: Equatable, Sendable {
    case ignored
    case refreshed(BackendOnlyRendererConfigIdentity)

    var identity: BackendOnlyRendererConfigIdentity? {
        switch self {
        case .ignored:
            nil
        case .refreshed(let identity):
            identity
        }
    }
}

enum BackendOnlyRendererConfigRefreshError: Error, Equatable, Sendable {
    case inconsistentRevision
    case staleReceipt
}

/// Fences old-config pixels before asking the daemon to upsert its newest snapshot.
@MainActor
struct BackendOnlyRendererConfigRefresh {
    static func perform(
        current: BackendOnlyRendererConfigIdentity?,
        invalidation: BackendRendererConfigInvalidated,
        retireIngress: @MainActor () async throws -> Void,
        configure: @MainActor () async throws -> BackendOnlyRendererConfigIdentity
    ) async throws -> BackendOnlyRendererConfigRefreshOutcome {
        if let current {
            if current.revision > invalidation.revision {
                return .ignored
            }
            if current.revision == invalidation.revision {
                guard current.digest == invalidation.digest else {
                    throw BackendOnlyRendererConfigRefreshError.inconsistentRevision
                }
                return .ignored
            }
        }

        // This closure must synchronously retire drawable ingress before its
        // first suspension. The old generation is then unable to present while
        // the daemon resolves and upserts the replacement configuration.
        try await retireIngress()
        let configured = try await configure()
        guard configured.revision >= invalidation.revision else {
            throw BackendOnlyRendererConfigRefreshError.staleReceipt
        }
        if configured.revision == invalidation.revision,
           configured.digest != invalidation.digest {
            throw BackendOnlyRendererConfigRefreshError.inconsistentRevision
        }
        return .refreshed(configured)
    }
}
