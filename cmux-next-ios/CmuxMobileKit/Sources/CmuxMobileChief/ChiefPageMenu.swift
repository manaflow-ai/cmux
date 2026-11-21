#if os(iOS)
import CmuxConversationCore
import CmuxConversationUI
import Observation
import SwiftUI
import UIKit

/// Chief's page menu, the conversation header's trailing button: Invite to
/// cmux (``ChiefInvite``), Chat Colors… (``ChiefChatColors``) and the Chief
/// zoom (the Mac's Chief: Zoom In, Zoom Out and Actual Size, ``ChiefTextZoom``). Also Reply with Selection, which
/// the bubble's text selection menu offers (the Mac's Reply to Selection).
enum ChiefPageMenu {
    /// The header glyph and its spoken label.
    static let symbol = "ellipsis"
    static var title: String { String(localized: "mobile.chief.menu.more", defaultValue: "More", bundle: .module) }

    static var zoomInTitle: String { String(localized: "mobile.chief.zoom.in", defaultValue: "Zoom In", bundle: .module) }
    static var zoomOutTitle: String { String(localized: "mobile.chief.zoom.out", defaultValue: "Zoom Out", bundle: .module) }
    static var actualSizeTitle: String { String(localized: "mobile.chief.zoom.actual", defaultValue: "Actual Size", bundle: .module) }
    static var chatColorsTitle: String { String(localized: "mobile.chief.menu.chatColors", defaultValue: "Chat Colors…", bundle: .module) }

    /// The zoom section's title with the size now, as the Mac's zoom indicator shows it.
    static func textSizeTitle(percent: Int) -> String {
        let format = String(localized: "mobile.chief.zoom.title", defaultValue: "Text Size: %@", bundle: .module)
        return String(format: format, (Double(percent) / 100).formatted(.percent))
    }

    /// Reply with Selection: the reply to that message opens with the
    /// selected words quoted (the Mac's Markdown quote) before what the
    /// person had already typed, so nothing typed is lost.
    @MainActor
    static func replyWithSelection(_ reply: ConversationSelectionReply, in conversation: ConversationViewController) {
        conversation.beginReply(toMessageID: reply.messageID, prefix: reply.markdownQuote)
    }
}

extension ChiefConversationContainer {
    /// The person's own text size: the container's traits (the conversation's
    /// carry the zoom).
    var systemTextSize: ConversationTextSize {
        ConversationTextSize(traitCollection.preferredContentSizeCategory) ?? .standard
    }

    func installPageMenu() {
        let invite = UIAction(title: ChiefInvite.actionTitle, image: UIImage(systemName: ChiefInvite.symbol)) { [weak self] _ in
            guard let self else { return }
            self.presentInvite(anchor: self.conversation.view.firstSubview { $0.accessibilityIdentifier == "conversation.header.trailing" })
        }
        // Built each time the menu opens, so the size, what can still zoom and
        // whether the chat is known yet (Chat Colors) are current.
        let rest = UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self.map { [$0.chatColorsAction(), $0.zoomMenu()] } ?? [])
        }
        conversation.headerActionMenu = UIMenu(children: [invite, rest])
        applyTextZoom()
        observeTextZoom()
        applyChatColors()
        observeChatColors()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (container: ChiefConversationContainer, _: UITraitCollection) in
            container.applyTextZoom()
        }
    }

    func zoomMenu() -> UIMenu {
        let zoom = ChiefTextZoom.shared
        let system = systemTextSize
        let zoomIn = UIAction(title: ChiefPageMenu.zoomInTitle, image: UIImage(systemName: "plus.magnifyingglass"),
                              attributes: zoom.canZoomIn(system: system) ? [] : .disabled) { [weak self] _ in
            guard let self else { return }
            ChiefTextZoom.shared.zoomIn(system: self.systemTextSize)
        }
        let zoomOut = UIAction(title: ChiefPageMenu.zoomOutTitle, image: UIImage(systemName: "minus.magnifyingglass"),
                               attributes: zoom.canZoomOut(system: system) ? [] : .disabled) { [weak self] _ in
            guard let self else { return }
            ChiefTextZoom.shared.zoomOut(system: self.systemTextSize)
        }
        let actual = UIAction(title: ChiefPageMenu.actualSizeTitle, image: UIImage(systemName: "1.magnifyingglass"),
                              attributes: zoom.percent(system: system) == 100 ? .disabled : []) { _ in
            ChiefTextZoom.shared.actualSize()
        }
        return UIMenu(title: ChiefPageMenu.textSizeTitle(percent: zoom.percent(system: system)), options: .displayInline,
                      children: [zoomIn, zoomOut, actual])
    }

    /// This chat's key in ``ChiefChatColors`` (nil until the conversation is known).
    var chatColorsKey: String? {
        session.conversationID.map { ChiefChatColors.key(macID: session.macID, conversation: $0) }
    }

    func chatColorsAction() -> UIAction {
        UIAction(title: ChiefPageMenu.chatColorsTitle, image: UIImage(systemName: "paintpalette"),
                 attributes: chatColorsKey == nil ? .disabled : []) { [weak self] _ in
            self?.presentChatColors()
        }
    }

    /// Chat Colors…: the sheet over the conversation, which shows each pick live under it.
    func presentChatColors() {
        guard let key = chatColorsKey, presentedViewController == nil, conversation.presentedViewController == nil else { return }
        view.endEditing(true)
        let sheet = UIHostingController(rootView: ChiefChatColorsSheet(key: key))
        sheet.modalPresentationStyle = .pageSheet
        if let controller = sheet.sheetPresentationController {
            controller.detents = [.medium(), .large()]
            controller.largestUndimmedDetentIdentifier = .medium
            controller.prefersGrabberVisible = true
        }
        present(sheet, animated: true)
    }

    /// The conversation draws in this chat's own colours (none: Messages').
    func applyChatColors() {
        let key = chatColorsKey
        appliedChatColorsKey = key
        let colors = key.map { ChiefChatColors.shared.colors(for: $0) }
        conversation.bubbleColors = colors?.isEmpty == false ? colors : nil
    }

    /// A pick in the sheet (or on another open screen of the same chat) shows at once.
    private func observeChatColors() {
        withObservationTracking {
            _ = ChiefChatColors.shared.chats
            // The chat's Mac named later (the coordinator) is another chat's key.
            _ = session.macID
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.applyChatColors()
                self?.observeChatColors()
            }
        }
    }

    /// The conversation draws at the saved zoom over the person's own size.
    func applyTextZoom() {
        conversation.textSize = ChiefTextZoom.shared.textSize(system: systemTextSize)
    }

    /// Every open Chief follows a zoom made on any of them.
    private func observeTextZoom() {
        withObservationTracking {
            _ = ChiefTextZoom.shared.step
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.applyTextZoom()
                self?.observeTextZoom()
            }
        }
    }
}
#endif
