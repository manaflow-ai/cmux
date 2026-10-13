#if canImport(UIKit)
import CmuxConversationCore
import UIKit

/// The pending rich link in the composer: when the draft opens or ends with
/// a URL, Messages fetches its card and shows it in the entry field (with a
/// discard button) before sending; the sent message carries that card.
@MainActor
final class ComposerLinkPreview {
    /// Set by the owner: fetches metadata (the store goes through the backend).
    var fetch: ((URL) async -> ConversationLinkPreview?)?
    /// Called when the card appears, changes size or goes away.
    var onChange: (() -> Void)?

    let container = UIView()
    private let card = ConversationLinkPreviewView()
    private let discard = UIButton(type: .custom)
    private(set) var preview: ConversationLinkPreview?
    private var dismissedURL: URL?
    private var task: Task<Void, Never>?

    /// CKUIBehavior entryViewLinkViewSize (300 x 210) and its plugin insets.
    static let maxCardWidth: CGFloat = 300
    static let inset: CGFloat = 6
    static let discardSize: CGFloat = 24
    static let discardInset: CGFloat = 8

    init() {
        container.isHidden = true
        container.addSubview(card)
        discard.setImage(UIImage(systemName: "xmark.circle.fill", withConfiguration: UIImage.SymbolConfiguration(paletteColors: [.white, UIColor.black.withAlphaComponent(0.55)])), for: .normal)
        discard.accessibilityLabel = String(localized: "conversation.link.removePreview", defaultValue: "Remove link preview", bundle: .module)
        discard.accessibilityIdentifier = "conversation.composer.removeLinkPreview"
        discard.addAction(UIAction { [weak self] _ in self?.dismiss() }, for: .touchUpInside)
        container.addSubview(discard)
    }

    /// The card a send should carry (nil until the metadata arrived).
    var sendablePreview: ConversationLinkPreview? {
        guard let preview, preview.state == .loaded else { return nil }
        return preview
    }

    func textChanged(_ text: String) {
        let url = Self.cardURL(in: text)
        guard url != preview?.url else { return }
        task?.cancel()
        guard let url, url != dismissedURL else {
            set(nil)
            return
        }
        set(ConversationLinkPreview(url: url, state: .loading))
        task = Task { [weak self] in
            let fetched = await self?.fetch?(url)
            guard let self, !Task.isCancelled, self.preview?.url == url else { return }
            var loaded = fetched ?? ConversationLinkPreview(url: url)
            loaded.state = .loaded
            self.set(loaded)
        }
    }

    func reset() {
        task?.cancel()
        dismissedURL = nil
        set(nil)
    }

    private func dismiss() {
        dismissedURL = preview?.url
        task?.cancel()
        set(nil)
    }

    private func set(_ value: ConversationLinkPreview?) {
        preview = value
        container.isHidden = value == nil
        onChange?()
    }

    /// Height the card adds above the text, for a field `width` wide.
    func height(forFieldWidth width: CGFloat) -> CGFloat {
        guard let preview else { return 0 }
        let layout = ConversationLinkPreviewView.layout(for: preview, maxWidth: min(Self.maxCardWidth, width - 2 * Self.inset))
        return layout.size.height + 2 * Self.inset
    }

    func layout(fieldWidth width: CGFloat) {
        guard let preview else { return }
        let layout = ConversationLinkPreviewView.layout(for: preview, maxWidth: min(Self.maxCardWidth, width - 2 * Self.inset))
        container.frame = CGRect(x: 0, y: 0, width: width, height: layout.size.height + 2 * Self.inset)
        // No tail in the entry field; the bubble outline's tail column is
        // trimmed by offsetting the leading-side frame.
        card.frame = CGRect(x: Self.inset - ConversationTheme.tailWidth, y: Self.inset, width: layout.size.width + ConversationTheme.tailWidth, height: layout.size.height)
        card.configure(preview: preview, layout: layout, side: .leading, tail: false)
        discard.frame = CGRect(
            x: card.frame.maxX - Self.discardInset - Self.discardSize,
            y: card.frame.minY + Self.discardInset,
            width: Self.discardSize, height: Self.discardSize
        )
    }

    /// The URL that becomes a card: one that opens or ends the draft.
    static func cardURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = detector.matches(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed))
        for match in [matches.first, matches.last].compactMap({ $0 }) {
            guard let url = match.url, url.scheme?.hasPrefix("http") == true else { continue }
            if ConversationLinkSplit.split(text: trimmed, preview: ConversationLinkPreview(url: url)) != nil { return url }
        }
        return nil
    }
}
#if DEBUG
public extension ConversationViewController {
    /// Lab hook: replaces the composer draft as if typed (headless runs have no touch input).
    func labSetDraft(_ text: String) {
        composer.text = text
    }
}
#endif
#endif
