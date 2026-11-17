import AppKit
import Bonsplit
import CmuxHomeCore
import Foundation

/// Resolves the live in-process source behind an opaque pane-transfer payload.
struct PaneTransferSourceResolver {
    enum Source: Equatable {
        case vaultSession(SessionEntry)
        case filePreview(FilePreviewDragEntry)
        /// A Cloud tree row: catalog resources (terminals, screens, browsers) on this Mac or a
        /// machine — one, or a whole workspace's worth.
        case surfaceResources(SurfaceResourceGroup)
        /// A sidebar workspace row: dropping it on a pane merges its tabs there.
        case workspaceMerge(UUID)
        /// A Chief Home row: dropping it creates/focuses that conversation in a pane.
        case chiefConversation(ConversationID?)
        case rightSidebarTool(RightSidebarMode)
        case surface
    }

    typealias VaultSessionRegistry = @MainActor () -> SessionDragRegistry?
    typealias TabTransferRegistry = @MainActor () -> TabDragTransferRegistry?
    typealias FilePreviewLookup = @MainActor (UUID) -> FilePreviewDragEntry?
    typealias SurfaceResourceLookup = @MainActor (UUID) -> SurfaceResourceGroup?
    typealias LivenessLookup = @MainActor (UUID) -> Bool
    typealias WorkspaceMergeLookup = @MainActor (UUID) -> UUID?
    typealias ChiefConversationLookup = @MainActor (UUID) -> ConversationID?
    /// Outer nil means ordinary source; inner nil means canonical default Chief.
    typealias CanonicalChiefLookup = @MainActor (UUID) -> ConversationID??

    private let vaultSessionRegistry: VaultSessionRegistry
    private let tabTransferRegistry: TabTransferRegistry
    private let filePreview: FilePreviewLookup
    private let surfaceResource: SurfaceResourceLookup
    private let surfaceIsLive: LivenessLookup
    private let workspaceMerge: WorkspaceMergeLookup
    private let chiefConversation: ChiefConversationLookup
    private let canonicalChief: CanonicalChiefLookup

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
        },
        workspaceMerge: @escaping WorkspaceMergeLookup = { id in
            WorkspaceMergeDragRegistry.shared.workspaceId(id: id)
        },
        chiefConversation: @escaping ChiefConversationLookup = { id in
            guard ChiefPaneDragRegistry.shared.contains(id) else { return nil }
            return ChiefPaneDragRegistry.shared.conversationID(for: id)
        },
        canonicalChief: @escaping CanonicalChiefLookup = { id in
            guard let app = AppDelegate.shared else { return nil }
            if let location = app.locateContainerSurface(tabId: id),
               case .workspace(_, let workspace, let panelID, _) = location,
               let chief = workspace.panels[panelID] as? ChiefPanel, chief.isHome {
                return .some(chief.conversationID)
            }
            if let workspaceID = WorkspaceMergeDragRegistry.shared.workspaceId(id: id),
               let workspace = app.workspaceFor(tabId: workspaceID),
               let chief = workspace.panels.values.compactMap({ $0 as? ChiefPanel }).first(where: \.isHome) {
                return .some(chief.conversationID)
            }
            return nil
        }
    ) {
        self.vaultSessionRegistry = vaultSessionRegistry
        self.tabTransferRegistry = tabTransferRegistry
        self.filePreview = filePreview
        self.surfaceResource = surfaceResource
        self.surfaceIsLive = surfaceIsLive
        self.workspaceMerge = workspaceMerge
        self.chiefConversation = chiefConversation
        self.canonicalChief = canonicalChief
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
        if let mode = transfer.rightSidebarToolMode { return .rightSidebarTool(mode) }
        if let source = registeredSource(id: transfer.tabId) {
            return source
        }
        if surfaceIsLive(transfer.tabId) { return .surface }
        return nil
    }

    /// Resolves a synthetic source registered outside Bonsplit's live tab model.
    @MainActor
    func registeredSource(id: UUID, pasteboard: NSPasteboard = NSPasteboard(name: .drag)) -> Source? {
        if let transfer = transfer(from: pasteboard), transfer.tabId == id,
           let mode = transfer.rightSidebarToolMode { return .rightSidebarTool(mode) }
        if let entry = vaultSessionRegistry()?.entry(id: id) {
            return .vaultSession(entry)
        }
        if let entry = filePreview(id) { return .filePreview(entry) }
        if let group = surfaceResource(id) { return .surfaceResources(group) }
        if let conversation = canonicalChief(id) { return .chiefConversation(conversation) }
        if let workspaceId = workspaceMerge(id) { return .workspaceMerge(workspaceId) }
        if chiefConversation(id) != nil || ChiefPaneDragRegistry.shared.contains(id) {
            return .chiefConversation(chiefConversation(id))
        }
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
        case .workspaceMerge:
            WorkspaceMergeDragRegistry.shared.discard(id: id)
        case .chiefConversation:
            ChiefPaneDragRegistry.shared.discard(id)
            WorkspaceMergeDragRegistry.shared.discard(id: id)
        case .surface, .rightSidebarTool:
            break
        }
    }

    /// Revokes routing for an accepted source while preserving native ownership.
    ///
    /// A live Bonsplit source is completed by its AppKit `endedAt` callback;
    /// this method only removes the capability used to route subsequent drops.
    @MainActor
    func finishAcceptedDrop(
        _ source: Source,
        id: UUID,
        pasteboard: NSPasteboard
    ) {
        switch source {
        case .surface, .rightSidebarTool:
            tabTransferRegistry()?.finish(from: pasteboard)
        case .chiefConversation:
            finish(source, id: id)
            tabTransferRegistry()?.finish(from: pasteboard)
        case .vaultSession, .filePreview, .surfaceResources, .workspaceMerge:
            finish(source, id: id)
        }
    }
}
