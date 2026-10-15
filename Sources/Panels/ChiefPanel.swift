import AppKit
import CmuxHomeCore
import Combine

/// A workspace pane that shows one Chief conversation beside the user's work.
///
/// The conversation lives in `ChiefService`; the panel only remembers which
/// conversation it shows (persisted with the session) and relays focus
/// requests to `ChiefPanelView`, which puts the caret in its compose field.
@MainActor
final class ChiefPanel: Panel {
    let id: UUID
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .chief

    /// The conversation this pane shows; nil means Chief's default conversation.
    @Published var conversationID: ConversationID?

    /// Bumped on every `focus()`; `ChiefPanelView` observes it to focus its compose field.
    @Published private(set) var focusRequestGeneration = 0

    var displayTitle: String {
        ChiefStrings.chiefName
    }

    var displayIcon: String? { Self.iconSystemName }

    /// The SF Symbol for Chief tabs, the sidebar Home row and canvas cards.
    static let iconSystemName = "bubble.left.and.bubble.right"

    init(id: UUID = UUID(), conversationID: ConversationID? = nil) {
        self.id = id
        self.conversationID = conversationID
    }

    func close() {}

    func focus() {
        focusRequestGeneration &+= 1
    }

    func unfocus() {}

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
    }
}
