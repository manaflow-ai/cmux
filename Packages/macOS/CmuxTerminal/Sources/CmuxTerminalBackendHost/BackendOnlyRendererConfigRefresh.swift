internal import CmuxTerminalBackend

typealias BackendOnlyRendererConfigIdentity = BackendRendererConfigIdentity

/// Fences old-config pixels before asking the daemon to upsert its newest snapshot.
@MainActor
func performBackendOnlyRendererConfigRefresh(
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
       configured.digest != invalidation.digest
    {
        throw BackendOnlyRendererConfigRefreshError.inconsistentRevision
    }
    return .refreshed(configured)
}
