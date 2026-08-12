import Foundation

/// Resolves the live in-process owner behind an opaque pane-transfer payload.
@MainActor
struct PaneTransferSourceResolver {
    enum Source: Equatable {
        case vaultSession
        case filePreview
        case surface
    }

    typealias LivenessLookup = @MainActor (UUID) -> Bool

    private let vaultSessionIsLive: LivenessLookup
    private let filePreviewIsLive: LivenessLookup
    private let surfaceIsLive: LivenessLookup

    init(
        vaultSessionIsLive: @escaping LivenessLookup = { id in
            SessionDragRegistry.shared.contains(id: id)
        },
        filePreviewIsLive: @escaping LivenessLookup = { id in
            FilePreviewDragRegistry.shared.contains(id: id)
        },
        surfaceIsLive: @escaping LivenessLookup = { id in
            AppDelegate.shared?.locateContainerSurface(tabId: id) != nil
        }
    ) {
        self.vaultSessionIsLive = vaultSessionIsLive
        self.filePreviewIsLive = filePreviewIsLive
        self.surfaceIsLive = surfaceIsLive
    }

    /// Rejects serialized lookalikes unless their source is still owned by cmux.
    func source(for transfer: PaneDragTransfer) -> Source? {
        guard transfer.isFromCurrentProcess else { return nil }
        if vaultSessionIsLive(transfer.tabId) { return .vaultSession }
        if filePreviewIsLive(transfer.tabId) { return .filePreview }
        if surfaceIsLive(transfer.tabId) { return .surface }
        return nil
    }
}
