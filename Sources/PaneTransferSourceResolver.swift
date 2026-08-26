import AppKit
import Bonsplit
import Foundation

/// Resolves the live in-process source behind an opaque pane-transfer payload.
struct PaneTransferSourceResolver {
    enum Source: Equatable {
        case vaultSession(SessionEntry)
        case filePreview(FilePreviewDragEntry)
        /// A Cloud tree row: a catalog resource (terminal, screen, or browser) on this Mac or a machine.
        case surfaceResource(SurfaceResourceID)
        case surface
    }

    typealias VaultSessionRegistry = @MainActor () -> SessionDragRegistry?
    typealias TabTransferRegistry = @MainActor () -> TabDragTransferRegistry?
    typealias FilePreviewLookup = @MainActor (UUID) -> FilePreviewDragEntry?
    typealias SurfaceResourceLookup = @MainActor (UUID) -> SurfaceResourceID?
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
            SurfaceResourceDragRegistry.shared.resource(id: id)
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

    /// Normalizes opaque Bonsplit capabilities and legacy JSON onto one transfer model.
    @MainActor
    func transfer(from pasteboard: NSPasteboard) -> PaneDragTransfer? {
        if let transfer = tabTransferRegistry()?.resolve(from: pasteboard) {
            return PaneDragTransfer(tabDragTransfer: transfer)
        }
        return PaneDragTransfer.decode(from: pasteboard)
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
        if let resource = surfaceResource(id) { return .surfaceResource(resource) }
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
        case .surfaceResource:
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
        case .vaultSession, .filePreview, .surfaceResource:
            finish(source, id: id)
        }
    }
}
