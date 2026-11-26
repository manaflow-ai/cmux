#if os(macOS)
import AppKit
import CmuxConversationCore

/// The pending rich link in the macOS composer: a URL that opens or ends the
/// draft shows its card above the text (spinner until the metadata arrives),
/// with a discard button. The sent message carries the card.
@MainActor
final class MacComposerLinkPreview {
    var fetch: ((URL) async -> ConversationLinkPreview?)?
    var onChange: (() -> Void)?

    let container = MacFlippedView()
    private let card = MacLinkPreviewView()
    private let discard = NSButton()
    private(set) var preview: ConversationLinkPreview?
    private var dismissedURL: URL?
    private var task: Task<Void, Never>?

    static let maxCardWidth: CGFloat = 300
    static let inset: CGFloat = 6
    static let discardSize: CGFloat = 17

    init() {
        container.isHidden = true
        container.addSubview(card)
        discard.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: String(localized: "conversation.link.removePreview", defaultValue: "Remove link preview", bundle: .module)
        )
        discard.isBordered = false
        discard.contentTintColor = .white
        discard.setAccessibilityIdentifier("conversation.composer.removeLinkPreview")
        discard.target = self
        discard.action = #selector(dismissTapped)
        container.addSubview(discard)
    }

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

    @objc private func dismissTapped() {
        dismissedURL = preview?.url
        task?.cancel()
        set(nil)
    }

    private func set(_ value: ConversationLinkPreview?) {
        preview = value
        container.isHidden = value == nil
        onChange?()
    }

    func height(forContentWidth width: CGFloat) -> CGFloat {
        guard let preview else { return 0 }
        return MacLinkPreviewView.layout(for: preview, maxWidth: min(Self.maxCardWidth, width - 2 * Self.inset)).size.height + 2 * Self.inset
    }

    func layout(contentWidth width: CGFloat) {
        guard let preview else { return }
        let layout = MacLinkPreviewView.layout(for: preview, maxWidth: min(Self.maxCardWidth, width - 2 * Self.inset))
        container.frame = CGRect(x: 0, y: 0, width: width, height: layout.size.height + 2 * Self.inset)
        card.frame = CGRect(x: Self.inset, y: Self.inset, width: layout.size.width + MacConversationTheme.tailWidth, height: layout.size.height)
        card.configure(preview: preview, layout: layout, side: .leading, tail: false)
        discard.frame = CGRect(x: card.frame.maxX - 3 - Self.discardSize, y: card.frame.minY + 3, width: Self.discardSize, height: Self.discardSize)
    }

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
#endif
