internal import CmuxTerminalBackend

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
            identity = invalidated
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
           candidate.digest != identity.digest
        {
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
            identity = candidate
        }
    }
}
