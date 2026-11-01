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
    /// Whether this pane is the canonical Chief Home anchor for its workspace.
    /// Home is protected in the split tree; dragged copies are ordinary Chief panes.
    let isHome: Bool

    /// The conversation this pane shows; nil means Chief's default conversation.
    @Published var conversationID: ConversationID?

    /// Bumped on every `focus()`; `ChiefPanelView` observes it to focus its compose field.
    @Published private(set) var focusRequestGeneration = 0

    var displayTitle: String {
        ChiefStrings.chiefName
    }

    var displayIcon: String? { Self.iconSystemName }

    /// The SF Symbol for canvas cards, and for tabs where the asset cannot draw.
    static let iconSystemName = "bubble.left.and.bubble.right"

    /// The tab's leading mark: Chief's cat face (the bundled `ChiefAvatar`
    /// art, ``ChiefAvatarArtwork/defaultFace``), so a Chief tab reads as
    /// Chief rather than as a generic chat. Bonsplit draws host assets at
    /// its compact mark size, beside the other tabs' glyphs.
    static let iconAssetName = "ChiefAvatar"

    init(id: UUID = UUID(), conversationID: ConversationID? = nil, isHome: Bool = false) {
        self.id = id
        self.conversationID = conversationID
        self.isHome = isHome
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
