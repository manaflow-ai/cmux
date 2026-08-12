import Foundation

/// Resolves the live in-process source behind an opaque pane-transfer payload.
struct PaneTransferSourceResolver {
    enum Source: Equatable {
        case vaultSession(SessionEntry)
        case filePreview(FilePreviewDragEntry)
        case surface
    }

    typealias VaultSessionRegistry = @MainActor () -> SessionDragRegistry?
    typealias FilePreviewLookup = @MainActor (UUID) -> FilePreviewDragEntry?
    typealias LivenessLookup = @MainActor (UUID) -> Bool

    private let vaultSessionRegistry: VaultSessionRegistry
    private let filePreview: FilePreviewLookup
    private let surfaceIsLive: LivenessLookup

    init(
        vaultSessionRegistry: @escaping VaultSessionRegistry = {
            AppDelegate.shared?.sessionDragRegistry
        },
        filePreview: @escaping FilePreviewLookup = { id in
            FilePreviewDragRegistry.shared.entry(id: id)
        },
        surfaceIsLive: @escaping LivenessLookup = { id in
            AppDelegate.shared?.locateContainerSurface(tabId: id) != nil
        }
    ) {
        self.vaultSessionRegistry = vaultSessionRegistry
        self.filePreview = filePreview
        self.surfaceIsLive = surfaceIsLive
    }

    /// Captures the live source value so execution does not re-read mutable drag state.
    @MainActor
    func source(for transfer: PaneDragTransfer) -> Source? {
        guard transfer.isFromCurrentProcess else { return nil }
        if let entry = vaultSessionRegistry()?.entry(id: transfer.tabId) {
            return .vaultSession(entry)
        }
        if let entry = filePreview(transfer.tabId) { return .filePreview(entry) }
        if surfaceIsLive(transfer.tabId) { return .surface }
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
        case .surface:
            break
        }
    }
}
