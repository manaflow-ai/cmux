import AppKit
import Bonsplit
import Foundation

/// Resolves the live in-process source behind an opaque pane-transfer payload.
struct PaneTransferSourceResolver {
    enum Source: Equatable {
        case vaultSession(SessionEntry)
        case filePreview(FilePreviewDragEntry)
        /// A Cloud tree row: catalog resources (terminals, screens, browsers) on this Mac or a
        /// machine — one, or a whole workspace's worth.
        case surfaceResources(SurfaceResourceGroup)
        case surface
    }

    typealias VaultSessionRegistry = @MainActor () -> SessionDragRegistry?
    typealias TabTransferRegistry = @MainActor () -> TabDragTransferRegistry?
    typealias FilePreviewLookup = @MainActor (UUID) -> FilePreviewDragEntry?
    typealias SurfaceResourceLookup = @MainActor (UUID) -> SurfaceResourceGroup?
    typealias LivenessLookup = @MainActor (UUID) -> Bool

    private let vaultSessionRegistry: VaultSessionRegistry
    private let tabTransferRegistry: TabTransferRegistry
    private let filePreview: FilePreviewLookup
    private let surfaceResource: SurfaceResourceLookup
    private let surfaceIsLive: LivenessLookup

    init(
        vaultSessionRegistry: @escaping VaultSessionRegistry = {
            AppDelegate.shared?.sessionDragRegistry
        },
        tabTransferRegistry: @escaping TabTransferRegistry = {
            AppDelegate.shared?.tabDragTransferRegistry
        },
        filePreview: @escaping FilePreviewLookup = { id in
            FilePreviewDragRegistry.shared.entry(id: id)
        },
        surfaceResource: @escaping SurfaceResourceLookup = { id in
            SurfaceResourceDragRegistry.shared.group(id: id)
        },
        surfaceIsLive: @escaping LivenessLookup = { id in
            AppDelegate.shared?.locateContainerSurface(tabId: id) != nil
        }
    ) {
        self.vaultSessionRegistry = vaultSessionRegistry
        self.tabTransferRegistry = tabTransferRegistry
        self.filePreview = filePreview
        self.surfaceResource = surfaceResource
        self.surfaceIsLive = surfaceIsLive
    }

    /// Resolves only an opaque live Bonsplit capability into one transfer model.
    ///
    /// A JSON payload from an earlier implementation can remain on AppKit's
    /// drag pasteboard after completion. Falling back to that payload would
    /// recreate a source from stale identity, so destination routing is gated
    /// exclusively by the injected live registry.
    @MainActor
    func transfer(from pasteboard: NSPasteboard) -> PaneDragTransfer? {
        let injectedRegistry = tabTransferRegistry()
        let transfer: TabDragTransfer?
        if let app = AppDelegate.shared,
           let injectedRegistry,
           injectedRegistry === app.tabDragTransferRegistry {
            transfer = app.liveTabDragCapabilityResolver.resolve(from: pasteboard)
        } else {
            transfer = injectedRegistry?.resolve(from: pasteboard)
        }
        guard let transfer else {
            return nil
        }
        return PaneDragTransfer(tabDragTransfer: transfer)
    }

    /// Captures the live source value so execution does not re-read mutable drag state.
    @MainActor
    func source(for transfer: PaneDragTransfer) -> Source? {
        guard transfer.isFromCurrentProcess else { return nil }
        if let source = registeredSource(id: transfer.tabId) {
            return source
        }
        if surfaceIsLive(transfer.tabId) { return .surface }
        return nil
    }

    /// Resolves a synthetic source registered outside Bonsplit's live tab model.
    @MainActor
    func registeredSource(id: UUID) -> Source? {
        if let entry = vaultSessionRegistry()?.entry(id: id) {
            return .vaultSession(entry)
        }
        if let entry = filePreview(id) { return .filePreview(entry) }
        if let group = surfaceResource(id) { return .surfaceResources(group) }
        return nil
    }

    /// Ends registry ownership only after the resolved source was handled.
    @MainActor
    func finish(_ source: Source, id: UUID) {
        switch source {
        case .vaultSession:
            vaultSessionRegistry()?.discard(id: id)
        case .filePreview:
            FilePreviewDragRegistry.shared.discard(id: id)
        case .surfaceResources:
            SurfaceResourceDragRegistry.shared.discard(id: id)
        case .surface:
            break
        }
    }

    /// Completes the accepted source, including a live Bonsplit drag session.
    @MainActor
    func finishAcceptedDrop(
        _ source: Source,
        id: UUID,
        pasteboard: NSPasteboard
    ) {
        switch source {
        case .surface:
            tabTransferRegistry()?.finish(from: pasteboard)
        case .vaultSession, .filePreview, .surfaceResources:
            finish(source, id: id)
        }
    }
}
