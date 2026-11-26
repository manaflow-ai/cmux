import AppKit
import Bonsplit
import CmuxHomeCore
import Foundation

/// Process-local capability for dragging a Chief conversation into a Bonsplit pane.
///
/// The conversation id stays in the in-process registry rather than on the
/// pasteboard. The pasteboard only carries Bonsplit's opaque capability, so a
/// stale drag can never create a conversation from an old payload.
@MainActor
final class ChiefPaneDragRegistry {
    static let shared = ChiefPaneDragRegistry()

    private struct Lease {
        let registration: TabDragTransferRegistration
        let registry: TabDragTransferRegistry
    }

    private var conversations: [UUID: String] = [:]
    private var leases: [UUID: Lease] = [:]

    func register(conversationID: ConversationID?) -> UUID {
        let id = UUID()
        conversations[id] = conversationID?.rawValue ?? ""
        return id
    }

    func conversationID(for id: UUID) -> ConversationID? {
        conversations[id].flatMap { $0.isEmpty ? nil : ConversationID($0) }
    }

    func contains(_ id: UUID) -> Bool {
        conversations[id] != nil
    }

    func retainLease(
        _ registration: TabDragTransferRegistration,
        in registry: TabDragTransferRegistry,
        for id: UUID
    ) {
        leases[id] = Lease(registration: registration, registry: registry)
    }

    func discard(_ id: UUID) {
        if let lease = leases.removeValue(forKey: id) {
            lease.registry.end(lease.registration)
        }
        conversations[id] = nil
    }
}

/// Builds the same live tab-transfer lease used by Bonsplit's native tab drags.
@MainActor
struct ChiefPaneDragPayload {
    let conversationID: ConversationID?
    let dragID: UUID

    init(conversationID: ConversationID?) {
        self.conversationID = conversationID
        dragID = ChiefPaneDragRegistry.shared.register(conversationID: conversationID)
    }

    func register(with registry: TabDragTransferRegistry) -> TabDragTransferRegistration? {
        registry.register(TabDragTransfer(
            tab: Bonsplit.Tab(
                id: TabID(uuid: dragID),
                title: ChiefStrings.chiefName,
                icon: ChiefPanel.iconSystemName,
                kind: "chiefConversation"
            ),
            // This is a synthetic source: it does not name a live Bonsplit pane.
            sourcePaneId: PaneID(id: dragID)
        ))
    }

    /// Creates a SwiftUI drag provider while retaining the transfer lease for
    /// the native drag. Accepted drops retire the registry entry through the
    /// normal pane-transfer completion path.
    func provider(with registry: TabDragTransferRegistry) -> NSItemProvider? {
        guard let registration = register(with: registry),
              registration.pasteboardItem.string(
                  forType: TabDragTransferRegistry.pasteboardType
              ) != nil else {
            ChiefPaneDragRegistry.shared.discard(dragID)
            return nil
        }

        ChiefPaneDragRegistry.shared.retainLease(registration, in: registry, for: dragID)
        let provider = NSItemProvider()
        provider.suggestedName = ChiefStrings.chiefName
        registration.register(with: provider)
        return provider
    }
}
