#if os(macOS)
import AppKit
import CmuxConversationCore
import CmuxConversationTranslation
import SwiftUI

/// Copy for translation UI, from Messages' own strings (ChatKit TRANSLATE_*).
enum MacTranslationText {
    static func languageName(_ language: Locale.Language) -> String {
        let code = language.languageCode?.identifier ?? language.minimalIdentifier
        return Locale.current.localizedString(forLanguageCode: code) ?? language.minimalIdentifier
    }

    static func captionText(_ caption: ConversationTranslationCaption) -> String {
        switch caption {
        case .translating:
            return String(localized: "conversation.translate.caption.translating", defaultValue: "Translating", bundle: .module)
        case .showOriginal:
            return String(localized: "conversation.translate.caption.showOriginal", defaultValue: "Show Original", bundle: .module)
        case .viewTranslation:
            return String(localized: "conversation.translate.caption.viewTranslation", defaultValue: "View Translation", bundle: .module)
        case .notDownloaded:
            return String(localized: "conversation.translate.caption.notDownloaded", defaultValue: "Language not downloaded", bundle: .module)
        case let .unsupported(language):
            let name = language.map { languageName(Locale.Language(identifier: $0)) } ?? ""
            return String(format: String(localized: "conversation.translate.caption.unsupported", defaultValue: "%@ translation is not supported on this Mac", bundle: .module), name)
        }
    }

    /// The translate glyph, then a clickable "Show Original" / "View
    /// Translation" (blue, like "Edited").
    static func caption(_ caption: ConversationTranslationCaption, alignment: NSTextAlignment) -> NSAttributedString {
        let tappable: Bool
        switch caption {
        case .showOriginal, .viewTranslation, .notDownloaded: tappable = true
        case .translating, .unsupported: tappable = false
        }
        let color: NSColor = tappable ? .systemBlue : MacConversationTheme.secondaryText
        let font = MacConversationTheme.editedFont
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        let result = NSMutableAttributedString()
        if let glyph = NSImage(systemSymbolName: "translate", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .medium).applying(.init(paletteColors: [color]))) {
            let attachment = NSTextAttachment()
            attachment.image = glyph
            attachment.bounds = CGRect(x: 0, y: font.descender + 1, width: glyph.size.width, height: glyph.size.height)
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: " "))
        }
        result.append(NSAttributedString(string: captionText(caption)))
        result.addAttributes([.font: font, .foregroundColor: color, .paragraphStyle: paragraph], range: NSRange(location: 0, length: result.length))
        return result
    }

    static func indicatorTitle(_ indicator: ConversationTranslationIndicator) -> String {
        switch indicator {
        case let .translating(source):
            return String(format: String(localized: "conversation.translate.indicator.translating", defaultValue: "Translating %@", bundle: .module), languageName(source))
        case .waitingForDownload:
            return String(localized: "conversation.translate.indicator.waiting", defaultValue: "Translation will begin when language is downloaded", bundle: .module)
        }
    }
}

/// The capsule above the composer while a conversation translates
/// automatically; clicking it offers Stop Translation (or the download).
final class MacTranslationIndicatorView: NSButton {
    static let height: CGFloat = 26
    var bottomConstraint: NSLayoutConstraint?
    var menuProvider: (() -> NSMenu)?

    init() {
        super.init(frame: .zero)
        if #available(macOS 26.0, *) {
            bezelStyle = .glass
        } else {
            bezelStyle = .push
        }
        controlSize = .regular
        font = .systemFont(ofSize: 12, weight: .medium)
        image = NSImage(systemSymbolName: "translate", accessibilityDescription: nil)
        imagePosition = .imageLeading
        imageHugsTitle = true
        target = self
        action = #selector(showMenu)
        setAccessibilityIdentifier("conversation.translation.indicator")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func showMenu() {
        guard let menu = menuProvider?() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }
}

extension MacConversationViewController {
    /// Wires on-device translation (macOS 15+) and the conversation indicator.
    /// Without the Translation framework the Translate item never appears.
    func installTranslation() {
        var hasTranslator = false
        #if DEBUG
        if ConversationLabTranslator.isRequested {
            store.translations.translator = ConversationLabTranslator()
            hasTranslator = true
        }
        #endif
        if !hasTranslator, #available(macOS 15.0, *) {
            let engine = ConversationTranslationEngine()
            // The session (and its download prompt) lives in this host; it
            // must stay in the window but draws nothing and takes no clicks.
            let host = NSHostingView(rootView: AnyView(engine.hostView))
            host.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
            host.setAccessibilityElement(false)
            view.addSubview(host, positioned: .below, relativeTo: nil)
            store.translations.translator = engine
        }
        let indicator = MacTranslationIndicatorView()
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.isHidden = true
        indicator.menuProvider = { [weak self] in self?.translationIndicatorMenu() ?? NSMenu() }
        view.addSubview(indicator)
        let bottom = indicator.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8)
        indicator.bottomConstraint = bottom
        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            bottom,
            indicator.heightAnchor.constraint(equalToConstant: MacTranslationIndicatorView.height),
        ])
        store.addObserver { [weak self] _ in self?.updateTranslationIndicator() }
    }

    private var translationIndicator: MacTranslationIndicatorView? {
        view.subviews.lazy.compactMap { $0 as? MacTranslationIndicatorView }.first
    }

    /// Places the indicator `aboveBottom` points above the composer (the
    /// reply banner's height) and returns the room it takes from the transcript.
    func layoutTranslationIndicator(aboveBottom: CGFloat) -> CGFloat {
        guard let indicator = translationIndicator, !indicator.isHidden else { return 0 }
        indicator.bottomConstraint?.constant = -8 - aboveBottom
        return MacTranslationIndicatorView.height + 8
    }

    func updateTranslationIndicator() {
        guard let indicatorView = translationIndicator else { return }
        let indicator = store.translations.indicator
        let wasHidden = indicatorView.isHidden
        indicatorView.isHidden = indicator == nil
        if let indicator { indicatorView.title = MacTranslationText.indicatorTitle(indicator) }
        if wasHidden != indicatorView.isHidden { view.needsLayout = true }
    }

    private func translationIndicatorMenu() -> NSMenu {
        let menu = NSMenu()
        if case let .waitingForDownload(source) = store.translations.indicator {
            let title = String(format: String(localized: "conversation.translate.indicator.download", defaultValue: "Download %@", bundle: .module), MacTranslationText.languageName(source))
            menu.addItem(MacClosureMenuItem(title: title) { [weak self] in self?.store.translations.retryAutomaticTranslation() })
        }
        menu.addItem(MacClosureMenuItem(title: String(localized: "conversation.translate.indicator.stop", defaultValue: "Stop Translation", bundle: .module)) { [weak self] in
            self?.store.translations.stopTranslating()
        })
        return menu
    }

    // MARK: Context menu

    /// "Translate ▸ This Message / Conversation"; "Show Original" / "Show
    /// Translation" once translated. Nil without on-device translation.
    func translateMenuItem(for model: MacMessageRowModel) -> NSMenuItem? {
        let translations = store.translations
        guard let message = store.message(rowID: model.rowID), translations.canTranslate(message) else { return nil }
        let symbol = NSImage(systemSymbolName: "translate", accessibilityDescription: nil)
        let rowID = model.rowID
        if translations.hasTranslation(rowID: rowID) {
            let title = translations.isShowingTranslation(rowID: rowID)
                ? String(localized: "conversation.menu.showOriginal", defaultValue: "Show Original", bundle: .module)
                : String(localized: "conversation.menu.showTranslation", defaultValue: "Show Translation", bundle: .module)
            let item = MacClosureMenuItem(title: title) { [weak self] in self?.store.translations.toggleOriginal(rowID: rowID) }
            item.image = symbol
            return item
        }
        let item = NSMenuItem(title: String(localized: "conversation.menu.translate", defaultValue: "Translate", bundle: .module), action: nil, keyEquivalent: "")
        item.image = symbol
        let submenu = NSMenu()
        submenu.addItem(MacClosureMenuItem(title: String(localized: "conversation.translate.message", defaultValue: "Translate This Message", bundle: .module)) { [weak self] in
            self?.translate(rowID: rowID, conversation: false)
        })
        submenu.addItem(MacClosureMenuItem(title: String(localized: "conversation.translate.conversation", defaultValue: "Translate Conversation", bundle: .module)) { [weak self] in
            self?.translate(rowID: rowID, conversation: true)
        })
        item.submenu = submenu
        return item
    }

    func translate(rowID: String, conversation: Bool, from source: Locale.Language? = nil) {
        guard let message = store.message(rowID: rowID) else { return }
        let outcome = conversation
            ? store.translations.translateConversation(from: message, source: source)
            : store.translations.translateMessage(message, from: source)
        if outcome == .needsSourceLanguage, source == nil {
            presentTranslateFrom(rowID: rowID, conversation: conversation)
        }
    }

    /// "Translate From" when the language can't be detected (or matches
    /// the Mac's language): a menu of supported languages at the bubble.
    private func presentTranslateFrom(rowID: String, conversation: Bool) {
        guard let translator = store.translations.translator else { return }
        let target = store.translations.targetLanguage
        Task { [weak self] in
            let languages = await translator.supportedLanguages()
            guard let self else { return }
            var seen = Set<String>()
            let choices = languages
                .filter { $0.languageCode != target.languageCode }
                .filter { seen.insert($0.languageCode?.identifier ?? $0.minimalIdentifier).inserted }
                .sorted { MacTranslationText.languageName($0).localizedStandardCompare(MacTranslationText.languageName($1)) == .orderedAscending }
            guard !choices.isEmpty else { return }
            let menu = NSMenu(title: String(localized: "conversation.translate.from", defaultValue: "Translate From", bundle: .module))
            let header = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for language in choices {
                menu.addItem(MacClosureMenuItem(title: MacTranslationText.languageName(language)) { [weak self] in
                    self?.translate(rowID: rowID, conversation: conversation, from: language)
                })
            }
            let anchor = self.view.convert(NSPoint(x: self.view.bounds.midX, y: self.view.bounds.midY), to: nil)
            menu.popUp(positioning: nil, at: self.view.convert(anchor, from: nil), in: self.view)
        }
    }
}
#endif

#if os(macOS) && DEBUG
extension MacConversationViewController {
    /// Lab verbs for scripted verification. `<match>` is `incoming` (newest
    /// message from someone else), `last`, or a substring of the original text.
    func labTranslationCommand(_ verb: String, _ argument: String) -> String {
        if verb == "untranslate" {
            store.translations.stopTranslating()
            return "ok"
        }
        if verb == "translationindicator" {
            return store.translations.indicator.map { "indicator " + MacTranslationText.indicatorTitle($0) } ?? "indicator none"
        }
        guard let message = labTranslationTarget(argument) else { return "error no row" }
        switch verb {
        case "translate":
            return "outcome \(store.translations.translateMessage(message))"
        case "translateconv":
            return "outcome \(store.translations.translateConversation(from: message))"
        case "toggletranslation":
            store.translations.toggleOriginal(rowID: message.rowID)
            return "ok"
        case "translatemenu":
            guard let item = translateMenuItem(for: MacMessageRowModel(
                rowID: message.rowID, message: message, isOutgoing: message.senderID == store.meID, isGroup: false,
                senderName: nil, senderInitials: "", senderColorHex: nil, showsSenderName: false, showsAvatar: false,
                showsTail: false, isFirstInRun: false, footer: .none, replyQuote: nil, isEmojiOnly: false,
                reactionKinds: [], hasMyReaction: false
            )) else { return "menu none" }
            return "menu " + ([item.title] + (item.submenu?.items.map { "  " + $0.title } ?? [])).joined(separator: "|")
        default:
            let detected = store.translations.detectedLanguage(of: message)?.minimalIdentifier ?? "?"
            guard let shown = store.translations.presentation(for: message) else { return "translation none lang \(detected)" }
            return "translation \(shown.caption) lang \(detected) text \(shown.text)"
        }
    }

    private func labTranslationTarget(_ query: String) -> ConversationMessage? {
        store.messages.reversed().first { message in
            switch query {
            case "incoming": return message.senderID != store.meID && !message.text.isEmpty
            case "last", "": return true
            default: return message.text.contains(query)
            }
        }
    }
}
#endif
