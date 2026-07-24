import AppKit

enum TerminalBackendResolvedRenderConfigEvent: Equatable, Sendable {
    case available(TerminalBackendRenderConfigSnapshot)
    case unavailable
}

/// Injected registry that lets app-owned Ghostty host views mount thin compositors.
@MainActor
final class TerminalBackendPresentationRegistry {
    private struct ResolvedRenderConfigPublication {
        let publisherID: UUID
        var snapshot: TerminalBackendRenderConfigSnapshot
    }

    private var mounts: [UUID: TerminalBackendPresentationMount] = [:]
    private var resolvedRenderConfigs: [
        UUID: ResolvedRenderConfigPublication
    ] = [:]
    private var resolvedRenderConfigContinuations: [
        UUID: [
            UUID: AsyncStream<
                TerminalBackendResolvedRenderConfigEvent
            >.Continuation
        ]
    ] = [:]

    deinit {
        for continuations in resolvedRenderConfigContinuations.values {
            continuations.values.forEach { $0.finish() }
        }
    }

    func register(surfaceID: UUID) -> TerminalBackendPresentationMount {
        if let existing = mounts[surfaceID] { return existing }
        let mount = TerminalBackendPresentationMount(surfaceID: surfaceID)
        mounts[surfaceID] = mount
        return mount
    }

    func unregister(_ mount: TerminalBackendPresentationMount) {
        guard mounts[mount.surfaceID] === mount else { return }
        mounts.removeValue(forKey: mount.surfaceID)
        mount.invalidate()
    }

    @discardableResult
    func mountCompositor(surfaceID: UUID, in hostView: NSView) -> Bool {
        guard let mount = mounts[surfaceID] else { return false }
        mount.mount(in: hostView)
        return true
    }

    func unmountCompositor(surfaceID: UUID, from hostView: NSView? = nil) {
        mounts[surfaceID]?.unmount(from: hostView)
    }

    func compositorView(surfaceID: UUID) -> NSView? {
        mounts[surfaceID]?.compositorView
    }

    /// Starts one generation-fenced publication of the exact renderer
    /// configuration currently used by a Mac terminal presentation.
    ///
    /// A replacement runtime takes ownership immediately. Updates and teardown
    /// from the retired runtime are ignored after that ownership handoff.
    func beginResolvedRenderConfigPublication(
        surfaceID: UUID,
        snapshot: TerminalBackendRenderConfigSnapshot
    ) -> UUID {
        let publisherID = UUID()
        resolvedRenderConfigs[surfaceID] = ResolvedRenderConfigPublication(
            publisherID: publisherID,
            snapshot: snapshot
        )
        publish(.available(snapshot), surfaceID: surfaceID)
        return publisherID
    }

    func updateResolvedRenderConfig(
        surfaceID: UUID,
        publisherID: UUID,
        snapshot: TerminalBackendRenderConfigSnapshot
    ) {
        guard var publication = resolvedRenderConfigs[surfaceID],
              publication.publisherID == publisherID else { return }
        guard publication.snapshot != snapshot else { return }
        publication.snapshot = snapshot
        resolvedRenderConfigs[surfaceID] = publication
        publish(.available(snapshot), surfaceID: surfaceID)
    }

    func endResolvedRenderConfigPublication(
        surfaceID: UUID,
        publisherID: UUID
    ) {
        guard resolvedRenderConfigs[surfaceID]?.publisherID == publisherID else {
            return
        }
        resolvedRenderConfigs.removeValue(forKey: surfaceID)
        publish(.unavailable, surfaceID: surfaceID)
    }

    func resolvedRenderConfig(
        surfaceID: UUID
    ) -> TerminalBackendRenderConfigSnapshot? {
        resolvedRenderConfigs[surfaceID]?.snapshot
    }

    func resolvedRenderConfigUpdates(
        surfaceID: UUID
    ) -> AsyncStream<TerminalBackendResolvedRenderConfigEvent> {
        let subscriberID = UUID()
        let pair = AsyncStream<
            TerminalBackendResolvedRenderConfigEvent
        >.makeStream(bufferingPolicy: .bufferingNewest(1))
        resolvedRenderConfigContinuations[
            surfaceID,
            default: [:]
        ][subscriberID] = pair.continuation
        if let snapshot = resolvedRenderConfigs[surfaceID]?.snapshot {
            pair.continuation.yield(.available(snapshot))
        } else {
            pair.continuation.yield(.unavailable)
        }
        pair.continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.resolvedRenderConfigContinuations[surfaceID]?[subscriberID] = nil
                if self.resolvedRenderConfigContinuations[surfaceID]?.isEmpty == true {
                    self.resolvedRenderConfigContinuations[surfaceID] = nil
                }
            }
        }
        return pair.stream
    }

    private func publish(
        _ event: TerminalBackendResolvedRenderConfigEvent,
        surfaceID: UUID
    ) {
        for continuation in resolvedRenderConfigContinuations[
            surfaceID,
            default: [:]
        ].values {
            continuation.yield(event)
        }
    }
}
