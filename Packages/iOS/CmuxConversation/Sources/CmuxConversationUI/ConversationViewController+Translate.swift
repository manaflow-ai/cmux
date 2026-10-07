#if canImport(UIKit)
import CmuxConversationCore
import CmuxConversationTranslation
import SwiftUI
import UIKit

/// Copy for translation UI, from Messages' own strings (ChatKit TRANSLATE_*).
enum ConversationTranslationText {
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
            return String(format: String(localized: "conversation.translate.caption.unsupported", defaultValue: "%@ translation is not supported on this device", bundle: .module), name)
        }
    }

    /// The caption under a translated bubble: the translate glyph, then a
    /// tappable "Show Original" / "View Translation" (blue, like "Edited").
    static func caption(_ caption: ConversationTranslationCaption, alignment: NSTextAlignment) -> NSAttributedString {
        let tappable: Bool
        switch caption {
        case .showOriginal, .viewTranslation, .notDownloaded: tappable = true
        case .translating, .unsupported: tappable = false
        }
        let color: UIColor = tappable ? .systemBlue : ConversationTheme.secondaryText
        let font = ConversationTheme.editedFont
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        let result = NSMutableAttributedString()
        if let glyph = UIImage(systemName: "translate", withConfiguration: UIImage.SymbolConfiguration(font: font))?
            .withTintColor(color, renderingMode: .alwaysOriginal) {
            let attachment = NSTextAttachment(image: glyph)
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
/// automatically; its menu stops translation (or asks for the download).
final class ConversationTranslationIndicatorView: UIButton {
    static let height: CGFloat = 32

    override init(frame: CGRect) {
        super.init(frame: frame)
        var configuration: UIButton.Configuration
        if #available(iOS 26.0, *) {
            configuration = .glass()
        } else {
            configuration = .gray()
            configuration.cornerStyle = .capsule
        }
        configuration.image = UIImage(systemName: "translate")
        configuration.imagePadding = 6
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 14)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .systemFont(ofSize: 13, weight: .medium)
            return attributes
        }
        configuration.baseForegroundColor = .label
        self.configuration = configuration
        showsMenuAsPrimaryAction = true
        accessibilityIdentifier = "conversation.translation.indicator"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setTitle(_ title: String) {
        configuration?.title = title
    }
}

extension ConversationViewController {
    /// Wires on-device translation (iOS 18+) and the conversation indicator.
    /// Without the Translation framework the Translate item never appears.
    func installTranslation() {
        var hasTranslator = false
        #if DEBUG
        if ConversationLabTranslator.isRequested {
            store.translations.translator = ConversationLabTranslator()
            hasTranslator = true
        }
        #endif
        if !hasTranslator, #available(iOS 18.0, *) {
            let engine = ConversationTranslationEngine()
            // The session (and its download prompt) lives in this host; it
            // must stay in the window but draws nothing and takes no touches.
            let host = UIHostingController(rootView: AnyView(engine.hostView))
            host.view.backgroundColor = .clear
            host.view.isUserInteractionEnabled = false
            host.view.isAccessibilityElement = false
            host.view.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            addChild(host)
            view.insertSubview(host.view, at: 0)
            host.didMove(toParent: self)
            store.translations.translator = engine
        }
        let indicator = ConversationTranslationIndicatorView()
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.isHidden = true
        view.insertSubview(indicator, belowSubview: composerContainer)
        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            indicator.bottomAnchor.constraint(equalTo: composerContainer.topAnchor, constant: -6),
            indicator.heightAnchor.constraint(equalToConstant: ConversationTranslationIndicatorView.height),
            indicator.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -32),
        ])
        store.addObserver { [weak self] _ in self?.updateTranslationIndicator() }
        #if DEBUG
        runTranslationLabStepIfRequested()
        #endif
    }

    private var translationIndicator: ConversationTranslationIndicatorView? {
        view.subviews.lazy.compactMap { $0 as? ConversationTranslationIndicatorView }.first
    }

    /// Room the indicator takes above the composer (added to the bottom inset).
    var translationIndicatorReserve: CGFloat {
        guard let indicator = translationIndicator, !indicator.isHidden else { return 0 }
        return ConversationTranslationIndicatorView.height + 6
    }

    func updateTranslationIndicator() {
        guard let indicatorView = translationIndicator else { return }
        let indicator = store.translations.indicator
        let wasHidden = indicatorView.isHidden
        indicatorView.isHidden = indicator == nil
        if let indicator {
            indicatorView.setTitle(ConversationTranslationText.indicatorTitle(indicator))
            var actions: [UIMenuElement] = []
            if case let .waitingForDownload(source) = indicator {
                let title = String(format: String(localized: "conversation.translate.indicator.download", defaultValue: "Download %@", bundle: .module), ConversationTranslationText.languageName(source))
                actions.append(UIAction(title: title, image: UIImage(systemName: "arrow.down.circle")) { [weak self] _ in
                    self?.store.translations.retryAutomaticTranslation()
                })
            }
            actions.append(UIAction(title: String(localized: "conversation.translate.indicator.stop", defaultValue: "Stop Translation", bundle: .module), image: UIImage(systemName: "xmark.circle")) { [weak self] _ in
                self?.store.translations.stopTranslating()
            })
            indicatorView.menu = UIMenu(children: actions)
        }
        if wasHidden != indicatorView.isHidden {
            view.setNeedsLayout()
        }
    }

    // MARK: Long-press menu

    /// "Translate" for an untranslated message; "Show Original" / "Show
    /// Translation" once it has one. Empty without on-device translation.
    func translateMenuItems(for model: MessageRowModel, cell: MessageCell) -> [MessageActionOverlay.MenuItem] {
        let translations = store.translations
        guard let message = store.message(rowID: model.rowID), translations.canTranslate(message) else { return [] }
        if translations.hasTranslation(rowID: model.rowID) {
            let showing = translations.isShowingTranslation(rowID: model.rowID)
            let title = showing
                ? String(localized: "conversation.menu.showOriginal", defaultValue: "Show Original", bundle: .module)
                : String(localized: "conversation.menu.showTranslation", defaultValue: "Show Translation", bundle: .module)
            return [.init(title: title, symbol: "translate") { [weak self] in
                self?.store.translations.toggleOriginal(rowID: model.rowID)
            }]
        }
        return [.init(title: String(localized: "conversation.menu.translate", defaultValue: "Translate", bundle: .module), symbol: "translate") { [weak self] in
            self?.presentTranslateChoice(for: model.rowID)
        }]
    }

    /// Messages asks: this message, or the whole conversation.
    func presentTranslateChoice(for rowID: String) {
        let sheet = UIAlertController(
            title: nil,
            message: String(localized: "conversation.translate.prompt", defaultValue: "Translate this message or automatically translate this conversation?", bundle: .module),
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: String(localized: "conversation.translate.message", defaultValue: "Translate This Message", bundle: .module), style: .default) { [weak self] _ in
            self?.translate(rowID: rowID, conversation: false)
        })
        sheet.addAction(UIAlertAction(title: String(localized: "conversation.translate.conversation", defaultValue: "Translate Conversation", bundle: .module), style: .default) { [weak self] _ in
            self?.translate(rowID: rowID, conversation: true)
        })
        sheet.addAction(UIAlertAction(title: String(localized: "conversation.translate.cancel", defaultValue: "Cancel", bundle: .module), style: .cancel))
        anchorPopover(sheet, rowID: rowID)
        present(sheet, animated: true)
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
    /// the device language).
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
                .sorted { ConversationTranslationText.languageName($0).localizedStandardCompare(ConversationTranslationText.languageName($1)) == .orderedAscending }
            guard !choices.isEmpty else { return }
            let sheet = UIAlertController(
                title: String(localized: "conversation.translate.from", defaultValue: "Translate From", bundle: .module),
                message: nil,
                preferredStyle: .actionSheet
            )
            for language in choices {
                sheet.addAction(UIAlertAction(title: ConversationTranslationText.languageName(language), style: .default) { [weak self] _ in
                    self?.translate(rowID: rowID, conversation: conversation, from: language)
                })
            }
            sheet.addAction(UIAlertAction(title: String(localized: "conversation.translate.cancel", defaultValue: "Cancel", bundle: .module), style: .cancel))
            self.anchorPopover(sheet, rowID: rowID)
            self.present(sheet, animated: true)
        }
    }

    /// iPad presents action sheets as popovers from the bubble.
    private func anchorPopover(_ controller: UIViewController, rowID: String) {
        guard let popover = controller.popoverPresentationController else { return }
        popover.sourceView = view
        if let indexPath = indexPath(for: rowID), let cell = collectionView.cellForItem(at: indexPath) as? MessageCell {
            popover.sourceRect = cell.convert(cell.liftedContentFrame, to: view)
        } else {
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        }
    }
}

#if DEBUG
extension ConversationViewController {
    /// Lab-only: `CMUX_CONVERSATION_LAB_TRANSLATE=menu|choice|message|conversation`
    /// drives the newest incoming message through the same paths a person
    /// uses, once history loads, for headless Simulator captures.
    func runTranslationLabStepIfRequested() {
        guard let step = ProcessInfo.processInfo.environment["CMUX_CONVERSATION_LAB_TRANSLATE"], !step.isEmpty else { return }
        var fired = false
        store.addObserver { [weak self] change in
            guard let self, !fired, change == .reset, self.store.hasLoadedNewest else { return }
            fired = true
            Task { @MainActor [weak self] in
                // Let the reset's reload and positioning land first.
                await Task.yield()
                self?.runTranslationLabStep(step)
            }
        }
    }

    private func runTranslationLabStep(_ step: String) {
        guard let message = store.messages.last(where: { $0.senderID != store.meID && !$0.text.isEmpty }) else { return }
        switch step {
        case "menu":
            collectionView.layoutIfNeeded()
            guard let indexPath = indexPath(for: message.rowID),
                  let cell = collectionView.cellForItem(at: indexPath) as? MessageCell,
                  case let .message(model) = rows[indexPath.item] else { return }
            presentActions(for: model, cell: cell, mode: .menu)
        case "choice":
            presentTranslateChoice(for: message.rowID)
        case "message":
            translate(rowID: message.rowID, conversation: false)
        case "conversation":
            translate(rowID: message.rowID, conversation: true)
        default:
            return
        }
    }
}
#endif
#endif
