#if os(iOS)
import CmuxConversationCore
import CmuxConversationUI
import Observation
import UIKit

/// Chief's page menu, the conversation header's trailing button: Invite to
/// cmux (``ChiefInvite``) and the Chief zoom (the Mac's Chief: Zoom In, Zoom
/// Out and Actual Size, ``ChiefTextZoom``). Also Reply with Selection, which
/// the bubble's text selection menu offers (the Mac's Reply to Selection).
enum ChiefPageMenu {
    /// The header glyph and its spoken label.
    static let symbol = "ellipsis"
    static var title: String { String(localized: "mobile.chief.menu.more", defaultValue: "More", bundle: .module) }

    static var zoomInTitle: String { String(localized: "mobile.chief.zoom.in", defaultValue: "Zoom In", bundle: .module) }
    static var zoomOutTitle: String { String(localized: "mobile.chief.zoom.out", defaultValue: "Zoom Out", bundle: .module) }
    static var actualSizeTitle: String { String(localized: "mobile.chief.zoom.actual", defaultValue: "Actual Size", bundle: .module) }

    /// The zoom section's title with the size now, as the Mac's zoom indicator shows it.
    static func textSizeTitle(percent: Int) -> String {
        let format = String(localized: "mobile.chief.zoom.title", defaultValue: "Text Size: %@", bundle: .module)
        return String(format: format, (Double(percent) / 100).formatted(.percent))
    }

    /// Reply with Selection: the reply to that message opens with the
    /// selected words quoted (the Mac's Markdown quote), then what the person
    /// had already typed, so nothing typed is lost.
    @MainActor
    static func replyWithSelection(_ reply: ConversationSelectionReply, in conversation: ConversationViewController) {
        let typed = (conversation.view.chiefFirstSubview { $0.accessibilityIdentifier == "conversation.composer.text" } as? UITextView)?.text ?? ""
        conversation.beginReply(toMessageID: reply.messageID, composerText: reply.markdownQuote + typed)
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
            self.presentInvite(anchor: self.conversation.view.chiefFirstSubview { $0.accessibilityIdentifier == "conversation.header.trailing" })
        }
        // Built each time the menu opens, so the size and what can still zoom are current.
        let zoom = UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self.map { [$0.zoomMenu()] } ?? [])
        }
        conversation.headerActionMenu = UIMenu(children: [invite, zoom])
        applyTextZoom()
        observeTextZoom()
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
                              attributes: zoom.step == 0 ? .disabled : []) { _ in
            ChiefTextZoom.shared.actualSize()
        }
        return UIMenu(title: ChiefPageMenu.textSizeTitle(percent: zoom.percent(system: system)), options: .displayInline,
                      children: [zoomIn, zoomOut, actual])
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

extension UIView {
    /// The first view under this one that matches (CmuxConversation marks its
    /// composer and header controls with accessibility identifiers).
    func chiefFirstSubview(where match: (UIView) -> Bool) -> UIView? {
        for view in subviews {
            if match(view) { return view }
            if let found = view.chiefFirstSubview(where: match) { return found }
        }
        return nil
    }
}
#endif
