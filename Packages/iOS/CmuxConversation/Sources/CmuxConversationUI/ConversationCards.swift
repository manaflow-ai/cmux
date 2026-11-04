#if canImport(UIKit)
import CmuxConversationCore
import SwiftUI
import UIKit

// Agent cards in the transcript (https://github.com/manaflow-ai/cmux/issues/25830):
// the live browser / computer card, the Secure Store sign-in card, and the
// next-step chips inside the reply bubble. Frames come from
// `MessageCellLayout` (`ConversationCardCellLayout`); taps reach the
// controller through `handleCardTap`, as poll taps do.

/// What a card row shows beyond the message: the state derived from the
/// messages after it.
struct CardRowModel: Hashable {
    /// Next-step choices a later message of mine sent word for word.
    var chosen: Set<String>
    /// A later message of mine said the sign-in was added.
    var signInAdded: Bool
    /// The buttons act (someone else's message, and I am connected).
    var interactive: Bool

    @MainActor
    static func attach(to model: MessageRowModel, store: ConversationStore) -> MessageRowModel {
        let message = model.message
        guard !message.cards.isEmpty else { return model }
        var model = model
        let messages = store.messages
        let index = store.messageIndex(id: message.id) ?? messages.count - 1
        model.cards = CardRowModel(
            chosen: message.nextSteps?.chosen(after: index, in: messages, meID: store.meID) ?? [],
            signInAdded: message.signInCard?.isAdded(after: index, in: messages, meID: store.meID) ?? false,
            interactive: store.meID != nil && message.senderID != store.meID && !message.isScheduled
        )
        return model
    }
}

/// A card button's action, from a tap or VoiceOver.
enum ConversationCardAction: Hashable {
    case openTarget
    case openScreenshot
    case addSignIn
    case choose(String)
}

// MARK: - Layout

/// The browser or Secure Store card, in its own coordinates.
struct ConversationCardLayout: Hashable {
    var size: CGSize
    var iconFrame: CGRect
    var titleFrame: CGRect
    var subtitleFrame: CGRect
    var spinnerFrame: CGRect?
    var imageFrame: CGRect?
    var buttonFrame: CGRect?
}

/// Next-step chips, in the chip block's coordinates.
struct ConversationChipsLayout: Hashable {
    var rows: [CGRect]
    var texts: [CGRect]
    var checks: [CGRect]
    var height: CGFloat
}

/// Where a message's cards sit in its cell (cell coordinates).
struct ConversationCardCellLayout {
    var cardFrame: CGRect?
    var card: ConversationCardLayout?
    var chipsFrame: CGRect?
    var chips: ConversationChipsLayout?
}

enum ConversationCardStyle {
    static let padding: CGFloat = 16
    static let iconSize: CGFloat = 44
    static let iconGap: CGFloat = 12
    static let sectionGap: CGFloat = 12
    static let buttonHeight: CGFloat = 44
    static let cornerRadius: CGFloat = 22
    static let screenshotRadius: CGFloat = 12
    static let spinnerSize: CGFloat = 20
    static let signInMinWidth: CGFloat = 240
    static let chipInset: CGFloat = 14
    static let chipCheck: CGFloat = 26
    static let chipSpacing: CGFloat = 8
    static let chipMinHeight: CGFloat = 44
    /// Between the reply's text and its first chip.
    static let chipsTopGap: CGFloat = 12

    static var titleFont: UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: .medium))
    }

    static var subtitleFont: UIFont { .preferredFont(forTextStyle: .subheadline) }
    static var buttonFont: UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: .medium))
    }

    static var chipFont: UIFont { ConversationTheme.bubbleFont }

    static let cardFill = ConversationTheme.incomingBubble
    /// The browser card's "Open browser" pill: lighter than the card.
    static let openFill = UIColor.resolving { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.10) : UIColor(white: 1, alpha: 0.55)
    }

    /// The Secure Store tile and Add pill: the page color on the gray card.
    static let addFill = UIColor.systemBackground
    static let browserTile = UIColor.resolving { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.16, green: 0.22, blue: 0.32, alpha: 1)
            : UIColor(red: 0.90, green: 0.94, blue: 0.99, alpha: 1)
    }

    static func measure(_ text: String, font: UIFont, width: CGFloat, lines: Int = 0) -> CGSize {
        guard !text.isEmpty, width > 0 else { return .zero }
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        let height = lines > 0 ? min(rect.height, font.lineHeight * CGFloat(lines)) : rect.height
        return CGSize(width: ceil(rect.width), height: ceil(height))
    }

    static func openTitle(_ card: ConversationBrowserCard) -> String {
        switch card.surface {
        case .browser: return String(localized: "conversation.card.openBrowser", defaultValue: "Open browser", bundle: .module)
        case .computer: return String(localized: "conversation.card.openDesktop", defaultValue: "Open desktop", bundle: .module)
        }
    }

    static var addTitle: String { String(localized: "conversation.card.signIn.add", defaultValue: "Add", bundle: .module) }
    static var addedTitle: String { String(localized: "conversation.card.signIn.added", defaultValue: "Added", bundle: .module) }

    /// The header row: icon tile, title over subtitle, and a spinner while live.
    private static func header(subtitle: String, live: Bool, width: CGFloat) -> (CGRect, CGRect, CGRect, CGRect?, CGFloat) {
        let textX = padding + iconSize + iconGap
        let spinner = live ? spinnerSize + 8 : 0
        let textWidth = max(40, width - textX - padding - spinner)
        let titleHeight = ceil(titleFont.lineHeight)
        let subtitleHeight = measure(subtitle, font: subtitleFont, width: textWidth, lines: 2).height
        let textHeight = titleHeight + 2 + subtitleHeight
        let rowHeight = max(iconSize, textHeight)
        let icon = CGRect(x: padding, y: padding + (rowHeight - iconSize) / 2, width: iconSize, height: iconSize)
        let textTop = padding + (rowHeight - textHeight) / 2
        let titleFrame = CGRect(x: textX, y: textTop, width: textWidth, height: titleHeight)
        let subtitleFrame = CGRect(x: textX, y: titleFrame.maxY + 2, width: textWidth, height: subtitleHeight)
        let spinnerFrame = live
            ? CGRect(x: width - padding - spinnerSize, y: padding + (rowHeight - spinnerSize) / 2, width: spinnerSize, height: spinnerSize)
            : nil
        return (icon, titleFrame, subtitleFrame, spinnerFrame, padding + rowHeight)
    }

    /// The browser card fills the bubble width; the Secure Store card hugs its text.
    static func cardLayout(_ card: ConversationCard, maxWidth: CGFloat) -> ConversationCardLayout? {
        switch card {
        case let .browser(browser):
            let width = maxWidth
            let (icon, title, subtitle, spinner, headerBottom) = header(subtitle: browser.step, live: browser.live, width: width)
            var y = headerBottom
            var imageFrame: CGRect?
            if let image = browser.image {
                let imageWidth = width - 2 * padding
                let ratio = image.width > 0 && image.height > 0 ? CGFloat(image.height) / CGFloat(image.width) : 0.625
                let height = round(imageWidth * min(1.25, max(0.35, ratio)))
                let frame = CGRect(x: padding, y: y + sectionGap, width: imageWidth, height: height)
                imageFrame = frame
                y = frame.maxY
            }
            var buttonFrame: CGRect?
            if browser.target != nil {
                let height = max(buttonHeight, ceil(buttonFont.lineHeight) + 20)
                buttonFrame = CGRect(x: padding, y: y + sectionGap, width: width - 2 * padding, height: height)
                y += sectionGap + height
            }
            return ConversationCardLayout(
                size: CGSize(width: width, height: y + padding), iconFrame: icon, titleFrame: title, subtitleFrame: subtitle,
                spinnerFrame: spinner, imageFrame: imageFrame, buttonFrame: buttonFrame
            )
        case let .signIn(signIn):
            let textNeed = max(
                measure(ConversationSignInCard.title, font: titleFont, width: maxWidth).width,
                measure(signIn.subtitle, font: subtitleFont, width: maxWidth).width
            )
            let width = min(maxWidth, max(signInMinWidth, padding + iconSize + iconGap + textNeed + padding))
            let (icon, title, subtitle, _, headerBottom) = header(subtitle: signIn.subtitle, live: false, width: width)
            let height = max(buttonHeight, ceil(buttonFont.lineHeight) + 20)
            let button = CGRect(x: padding, y: headerBottom + sectionGap, width: width - 2 * padding, height: height)
            return ConversationCardLayout(
                size: CGSize(width: width, height: button.maxY + padding), iconFrame: icon, titleFrame: title, subtitleFrame: subtitle,
                spinnerFrame: nil, imageFrame: nil, buttonFrame: button
            )
        case .nextSteps:
            return nil
        }
    }

    /// Full-width outlined rows, `width` wide, each text left and a check right.
    static func chipsLayout(_ choices: [String], width: CGFloat) -> ConversationChipsLayout {
        var rows: [CGRect] = []
        var texts: [CGRect] = []
        var checks: [CGRect] = []
        var y: CGFloat = 0
        let textWidth = max(40, width - chipInset - chipCheck - 2 * 10)
        for choice in choices {
            if !rows.isEmpty { y += chipSpacing }
            let text = measure(choice, font: chipFont, width: textWidth)
            let height = max(chipMinHeight, max(text.height, ceil(chipFont.lineHeight)) + 20)
            let row = CGRect(x: 0, y: y, width: width, height: height)
            rows.append(row)
            texts.append(CGRect(x: chipInset, y: y + (height - text.height) / 2, width: textWidth, height: text.height))
            checks.append(CGRect(x: width - 10 - chipCheck, y: y + (height - chipCheck) / 2, width: chipCheck, height: chipCheck))
            y += height
        }
        return ConversationChipsLayout(rows: rows, texts: texts, checks: checks, height: y)
    }
}

// MARK: - Views

/// The browser / computer card or the Secure Store card: a gray rounded
/// balloon with an icon tile, title and subtitle, the latest screenshot and
/// a full-width pill button.
final class ConversationCardView: UIView {
    private let iconTile = UIView()
    private let icon = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    let screenshot = UIImageView()
    private let button = UIView()
    private let buttonLabel = UILabel()
    private var imageTask: Task<Void, Never>?
    private var imageID: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = ConversationCardStyle.cardFill
        layer.cornerRadius = ConversationCardStyle.cornerRadius
        layer.cornerCurve = .continuous
        clipsToBounds = true
        iconTile.layer.cornerRadius = 10
        iconTile.layer.cornerCurve = .continuous
        icon.contentMode = .center
        iconTile.addSubview(icon)
        titleLabel.textColor = .label
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 2
        subtitleLabel.lineBreakMode = .byTruncatingTail
        screenshot.contentMode = .scaleAspectFill
        screenshot.clipsToBounds = true
        screenshot.backgroundColor = .systemBackground
        screenshot.layer.cornerRadius = ConversationCardStyle.screenshotRadius
        screenshot.layer.cornerCurve = .continuous
        screenshot.accessibilityIdentifier = "conversation.card.screenshot"
        button.layer.cornerCurve = .continuous
        buttonLabel.textAlignment = .center
        buttonLabel.textColor = .label
        button.addSubview(buttonLabel)
        for view in [iconTile, titleLabel, subtitleLabel, spinner, screenshot, button] {
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(card: ConversationCard, layout: ConversationCardLayout, state: CardRowModel?) {
        titleLabel.font = ConversationCardStyle.titleFont
        subtitleLabel.font = ConversationCardStyle.subtitleFont
        buttonLabel.font = ConversationCardStyle.buttonFont
        iconTile.frame = layout.iconFrame
        icon.frame = iconTile.bounds
        titleLabel.frame = layout.titleFrame
        subtitleLabel.frame = layout.subtitleFrame
        let symbol = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        switch card {
        case let .browser(browser):
            iconTile.backgroundColor = ConversationCardStyle.browserTile
            icon.image = UIImage(systemName: browser.surface == .browser ? "globe" : "display", withConfiguration: symbol)
            icon.tintColor = .systemBlue
            titleLabel.text = browser.title
            subtitleLabel.text = browser.step
            button.backgroundColor = ConversationCardStyle.openFill
            buttonLabel.text = ConversationCardStyle.openTitle(browser)
            buttonLabel.textColor = .label
            if let frame = layout.spinnerFrame {
                spinner.isHidden = false
                spinner.frame = frame
                spinner.startAnimating()
            } else {
                spinner.stopAnimating()
                spinner.isHidden = true
            }
            configureScreenshot(browser.image, frame: layout.imageFrame)
        case let .signIn(signIn):
            iconTile.backgroundColor = ConversationCardStyle.addFill
            icon.image = UIImage(systemName: "lock.shield", withConfiguration: symbol)
            icon.tintColor = .label
            titleLabel.text = ConversationSignInCard.title
            subtitleLabel.text = signIn.subtitle
            button.backgroundColor = ConversationCardStyle.addFill
            let added = state?.signInAdded == true
            buttonLabel.text = added ? ConversationCardStyle.addedTitle : ConversationCardStyle.addTitle
            buttonLabel.textColor = added ? .secondaryLabel : .label
            spinner.stopAnimating()
            spinner.isHidden = true
            configureScreenshot(nil, frame: nil)
        case .nextSteps:
            break
        }
        button.isHidden = layout.buttonFrame == nil
        if let frame = layout.buttonFrame {
            button.frame = frame
            button.layer.cornerRadius = frame.height / 2
            buttonLabel.frame = button.bounds.insetBy(dx: 12, dy: 0)
        }
    }

    private func configureScreenshot(_ attachment: ConversationAttachment?, frame: CGRect?) {
        guard let attachment, let frame else {
            imageTask?.cancel()
            imageTask = nil
            imageID = nil
            screenshot.image = nil
            screenshot.isHidden = true
            return
        }
        screenshot.isHidden = false
        screenshot.frame = frame
        guard imageID != attachment.id else { return }
        imageID = attachment.id
        imageTask?.cancel()
        let pixelWidth = frame.width * (window?.screen.scale ?? 3)
        if let cached = ConversationImageLoader.shared.cachedImage(for: attachment, pixelWidth: pixelWidth) {
            screenshot.image = cached
            return
        }
        // A live card's next screenshot: keep the previous one until it decodes.
        let id = attachment.id
        imageTask = Task { @MainActor [weak self] in
            let image = await ConversationImageLoader.shared.image(for: attachment, pixelWidth: pixelWidth)
            guard let self, self.imageID == id, !Task.isCancelled, let image else { return }
            self.screenshot.image = image
        }
    }

    /// Forgets the shown screenshot (the cell shows another row).
    func reset() {
        imageTask?.cancel()
        imageTask = nil
        imageID = nil
        screenshot.image = nil
    }
}

/// Next-step chips inside the reply bubble.
final class ConversationChipsView: UIView {
    private var rows: [(box: UIView, label: UILabel, check: UIImageView)] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(choices: [String], layout: ConversationChipsLayout, chosen: Set<String>, interactive: Bool) {
        while rows.count < choices.count {
            let box = UIView()
            box.layer.cornerRadius = 12
            box.layer.cornerCurve = .continuous
            box.layer.borderWidth = 1.5
            let label = UILabel()
            label.numberOfLines = 0
            let check = UIImageView()
            check.contentMode = .scaleAspectFit
            for view in [box, label, check] { addSubview(view) }
            rows.append((box, label, check))
        }
        for (index, row) in rows.enumerated() {
            let shown = index < choices.count && index < layout.rows.count
            row.box.isHidden = !shown
            row.label.isHidden = !shown
            row.check.isHidden = !shown
            guard shown else { continue }
            let isChosen = chosen.contains(choices[index])
            let dim = isChosen || !interactive
            row.box.frame = layout.rows[index]
            row.box.layer.borderColor = (dim ? UIColor.tertiaryLabel : UIColor.label).resolvedColor(with: traitCollection).cgColor
            row.label.frame = layout.texts[index]
            row.label.font = ConversationCardStyle.chipFont
            row.label.text = choices[index]
            row.label.textColor = dim ? .secondaryLabel : .label
            row.check.frame = layout.checks[index]
            // White check in a filled circle; muted once chosen.
            let palette = UIImage.SymbolConfiguration(paletteColors: [.systemBackground, dim ? .tertiaryLabel : .label])
            let size = UIImage.SymbolConfiguration(pointSize: ConversationCardStyle.chipCheck, weight: .regular)
            row.check.image = UIImage(systemName: "checkmark.circle.fill", withConfiguration: size.applying(palette))
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // Border colors are CGColors: re-resolve them for light and dark.
        for row in rows where !row.box.isHidden {
            let dim = row.label.textColor == .secondaryLabel
            row.box.layer.borderColor = (dim ? UIColor.tertiaryLabel : UIColor.label).resolvedColor(with: traitCollection).cgColor
        }
    }

    /// The chip under `point` (this view's coordinates).
    func chipIndex(at point: CGPoint) -> Int? {
        rows.firstIndex { !$0.box.isHidden && $0.box.frame.contains(point) }
    }
}

extension MessageCell {
    func configureCards(model: MessageRowModel, layout: MessageCellLayout) {
        let message = model.message
        if let frame = layout.cards?.cardFrame, let cardLayout = layout.cards?.card,
           let card = message.browserCard.map(ConversationCard.browser) ?? message.signInCard.map(ConversationCard.signIn) {
            cardView.isHidden = false
            cardView.frame = frame
            cardView.configure(card: card, layout: cardLayout, state: model.cards)
        } else if hasCardView {
            cardView.isHidden = true
            cardView.reset()
        }
        if let frame = layout.cards?.chipsFrame, let chips = layout.cards?.chips, let steps = message.nextSteps {
            chipsView.isHidden = false
            chipsView.frame = frame
            chipsView.configure(choices: steps.choices, layout: chips, chosen: model.cards?.chosen ?? [], interactive: model.cards?.interactive ?? false)
        } else if hasChipsView {
            chipsView.isHidden = true
        }
        cardAccessibilityElements = makeCardAccessibilityElements(model: model, layout: layout)
    }

    private func makeCardAccessibilityElements(model: MessageRowModel, layout: MessageCellLayout) -> [ConversationAccessibilityElement] {
        guard let cards = layout.cards else { return [] }
        let message = model.message
        let state = model.cards
        var elements: [ConversationAccessibilityElement] = []
        let shifted: (CGRect) -> CGRect = { [unowned self] rect in self.shiftable.convert(rect, to: self.contentView) }
        func element(_ label: String, frame: CGRect, traits: UIAccessibilityTraits, action: ConversationCardAction?) -> ConversationAccessibilityElement {
            let item = ConversationAccessibilityElement(accessibilityContainer: contentView)
            item.accessibilityLabel = label
            item.accessibilityTraits = traits
            item.frameProvider = { shifted(frame) }
            if let action {
                item.onActivate = { [weak self] in self?.cardActionHandler?(action) ?? false }
            }
            return item
        }
        if let frame = cards.cardFrame, let card = cards.card {
            if let browser = message.browserCard {
                let live = browser.live ? String(localized: "conversation.card.live", defaultValue: "In progress", bundle: .module) : nil
                let summary = element([browser.title, browser.step, live].compactMap { $0 }.joined(separator: ", "), frame: frame, traits: .staticText, action: nil)
                summary.accessibilityIdentifier = "conversation.card.browser.\(message.id)"
                elements.append(summary)
                if let image = card.imageFrame {
                    elements.append(element(
                        String(localized: "conversation.card.screenshot", defaultValue: "Latest screenshot", bundle: .module),
                        frame: image.offsetBy(dx: frame.minX, dy: frame.minY), traits: [.image, .button], action: .openScreenshot
                    ))
                }
                if let button = card.buttonFrame {
                    let open = element(ConversationCardStyle.openTitle(browser), frame: button.offsetBy(dx: frame.minX, dy: frame.minY), traits: .button, action: .openTarget)
                    open.accessibilityIdentifier = "conversation.card.open"
                    elements.append(open)
                }
            } else if let signIn = message.signInCard {
                let summary = element("\(ConversationSignInCard.title), \(signIn.subtitle)", frame: frame, traits: .staticText, action: nil)
                summary.accessibilityIdentifier = "conversation.card.signIn.\(message.id)"
                elements.append(summary)
                if let button = card.buttonFrame {
                    let added = state?.signInAdded == true
                    var traits: UIAccessibilityTraits = .button
                    if added || state?.interactive != true { traits.insert(.notEnabled) }
                    let add = element(added ? ConversationCardStyle.addedTitle : ConversationCardStyle.addTitle,
                                      frame: button.offsetBy(dx: frame.minX, dy: frame.minY), traits: traits, action: added ? nil : .addSignIn)
                    add.accessibilityHint = signIn.subtitle
                    add.accessibilityIdentifier = "conversation.card.add"
                    elements.append(add)
                }
            }
        }
        if let frame = cards.chipsFrame, let chips = cards.chips, let steps = message.nextSteps {
            for (index, choice) in steps.choices.enumerated() where index < chips.rows.count {
                let chosen = state?.chosen.contains(choice) == true
                var traits: UIAccessibilityTraits = .button
                if chosen { traits.insert(.selected) }
                if chosen || state?.interactive != true { traits.insert(.notEnabled) }
                let chip = element(choice, frame: chips.rows[index].offsetBy(dx: frame.minX, dy: frame.minY), traits: traits, action: chosen ? nil : .choose(choice))
                chip.accessibilityIdentifier = "conversation.card.choice.\(index)"
                elements.append(chip)
            }
        }
        return elements
    }
}

// MARK: - Controller

extension ConversationViewController {
    /// Handles taps on a message's cards; returns true when the tap was consumed.
    func handleCardTap(cell: MessageCell, model: MessageRowModel, local: CGPoint) -> Bool {
        guard let cards = cell.cellLayout?.cards else { return false }
        let shifted = cell.shiftable.convert(local, from: cell)
        if let frame = cards.chipsFrame, frame.contains(shifted), let steps = model.message.nextSteps {
            let point = CGPoint(x: shifted.x - frame.minX, y: shifted.y - frame.minY)
            if let index = cards.chips?.rows.firstIndex(where: { $0.contains(point) }), index < steps.choices.count {
                _ = performCardAction(.choose(steps.choices[index]), model: model)
            }
            return true
        }
        guard let frame = cards.cardFrame, frame.contains(shifted), let card = cards.card else { return false }
        let point = CGPoint(x: shifted.x - frame.minX, y: shifted.y - frame.minY)
        if let button = card.buttonFrame, button.insetBy(dx: 0, dy: -4).contains(point) {
            _ = performCardAction(model.message.browserCard != nil ? .openTarget : .addSignIn, model: model)
        } else if let image = card.imageFrame, image.contains(point) {
            _ = performCardAction(.openScreenshot, model: model)
        }
        return true
    }

    /// Runs a card button (a tap or VoiceOver). Returns whether it did something.
    @discardableResult
    func performCardAction(_ action: ConversationCardAction, model: MessageRowModel) -> Bool {
        let message = model.message
        switch action {
        case let .choose(choice):
            guard model.cards?.interactive == true, model.cards?.chosen.contains(choice) != true else { return false }
            UISelectionFeedbackGenerator().selectionChanged()
            sendCardMessage(choice)
            return true
        case .openTarget:
            guard let browser = message.browserCard else { return false }
            if onOpenBrowserCard?(browser, message.id) == true { return true }
            presentCardScreenshot(messageID: message.id)
            return true
        case .openScreenshot:
            guard message.browserCard?.image != nil else { return false }
            presentCardScreenshot(messageID: message.id)
            return true
        case .addSignIn:
            guard let signIn = message.signInCard, model.cards?.interactive == true, model.cards?.signInAdded != true else { return false }
            if onAddSignIn?(signIn, message.id) == true { return true }
            presentSignInOnMac(signIn)
            return true
        }
    }

    /// A message of mine from a card (a chosen next step, the Secure Store note).
    func sendCardMessage(_ text: String) {
        if let onSendCardMessage {
            onSendCardMessage(text)
        } else {
            _ = store.send(text: text)
        }
    }

    /// The live card's latest screenshot, full screen and zoomable; it follows
    /// the card's edits while it is open.
    func presentCardScreenshot(messageID: String) {
        guard presentedViewController == nil else { return }
        let viewer = ConversationCardScreenshotViewController(store: store, messageID: messageID)
        let navigation = UINavigationController(rootViewController: viewer)
        navigation.modalPresentationStyle = .fullScreen
        present(navigation, animated: true)
    }

    /// The sign-in is saved on the Mac: this iPhone has no way to hand a
    /// password to it, so the sheet says where to add it and can tell the
    /// agent the person will.
    func presentSignInOnMac(_ card: ConversationSignInCard) {
        guard presentedViewController == nil else { return }
        view.endEditing(true)
        var host: UIHostingController<ConversationSignInOnMacSheet>?
        let sheet = ConversationSignInOnMacSheet(card: card, dismiss: { host?.dismiss(animated: true) }, send: { [weak self] in
            self?.sendCardMessage(card.addOnMacMessage)
            host?.dismiss(animated: true)
        })
        let controller = UIHostingController(rootView: sheet)
        host = controller
        if let presentation = controller.sheetPresentationController {
            presentation.detents = [.medium(), .large()]
            presentation.prefersGrabberVisible = true
        }
        present(controller, animated: true)
    }
}

/// Add on the Secure Store card, on iPhone: where the sign-in goes, and a
/// button that tells the agent the person will add it on the Mac.
struct ConversationSignInOnMacSheet: View {
    let card: ConversationSignInCard
    let dismiss: () -> Void
    let send: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(String(format: String(localized: "conversation.card.signInSheet.title", defaultValue: "Add Your Sign-In for %@ on Your Mac", bundle: .module), card.site))
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text(String(localized: "conversation.card.signInSheet.body", defaultValue: "Sign-ins are kept in the Secure Store on the Mac that runs this chat, and the Mac fills the login page itself. Your password never goes through this chat. Open this chat on your Mac and tap Add on the Secure Store card.", bundle: .module))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button(action: send) {
                        Text(String(localized: "conversation.card.signInSheet.send", defaultValue: "I'll Add It on My Mac", bundle: .module))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityHint(Text(card.addOnMacMessage))
                    .accessibilityIdentifier("conversation.card.signInSheet.send")
                }
                .padding(24)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "conversation.retry.cancel", defaultValue: "Cancel", bundle: .module), action: dismiss)
                }
            }
        }
    }
}

/// A live browser card's latest screenshot, full screen: pinch and
/// double-tap zoom, the step under it, and the page in Safari when the
/// card names one. It follows the card's edits while open.
final class ConversationCardScreenshotViewController: UIViewController, UIScrollViewDelegate {
    private let store: ConversationStore
    private let messageID: String
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let stepLabel = UILabel()
    private let emptyLabel = UILabel()
    private var shownImageID: String?
    private var loadTask: Task<Void, Never>?

    init(store: ConversationStore, messageID: String) {
        self.store = store
        self.messageID = messageID
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = .image
        imageView.accessibilityLabel = String(localized: "conversation.card.screenshot", defaultValue: "Latest screenshot", bundle: .module)
        scrollView.addSubview(imageView)
        view.addSubview(scrollView)
        stepLabel.font = .preferredFont(forTextStyle: .subheadline)
        stepLabel.adjustsFontForContentSizeCategory = true
        stepLabel.textColor = .secondaryLabel
        stepLabel.numberOfLines = 2
        stepLabel.textAlignment = .center
        view.addSubview(stepLabel)
        emptyLabel.font = .preferredFont(forTextStyle: .body)
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.text = String(localized: "conversation.card.viewer.empty", defaultValue: "No screenshot yet.", bundle: .module)
        view.addSubview(emptyLabel)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        store.addObserver { [weak self] _ in self?.refresh() }
        refresh()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.safeAreaLayoutGuide.layoutFrame
        let stepHeight = ceil(stepLabel.sizeThatFits(CGSize(width: safe.width - 32, height: .greatestFiniteMagnitude)).height)
        stepLabel.frame = CGRect(x: safe.minX + 16, y: safe.maxY - stepHeight - 12, width: safe.width - 32, height: stepHeight)
        let area = CGRect(x: safe.minX, y: safe.minY, width: safe.width, height: stepLabel.frame.minY - 12 - safe.minY)
        if scrollView.frame != area {
            scrollView.frame = area
            scrollView.zoomScale = 1
            imageView.frame = scrollView.bounds
            scrollView.contentSize = scrollView.bounds.size
        }
        emptyLabel.frame = area.insetBy(dx: 24, dy: 0)
    }

    /// Reads the card again: a new step, a new screenshot, or the card gone.
    private func refresh() {
        guard isViewLoaded, let card = store.message(id: messageID)?.browserCard else {
            emptyLabel.isHidden = imageView.image != nil
            return
        }
        title = card.title
        stepLabel.text = card.step
        if let url = card.url {
            let open = UIBarButtonItem(image: UIImage(systemName: "safari"), primaryAction: UIAction { _ in
                UIApplication.shared.open(url)
            })
            open.accessibilityLabel = String(localized: "conversation.card.viewer.openPage", defaultValue: "Open Page in Safari", bundle: .module)
            navigationItem.rightBarButtonItem = open
        } else {
            navigationItem.rightBarButtonItem = nil
        }
        view.setNeedsLayout()
        guard let attachment = card.image else {
            emptyLabel.isHidden = imageView.image != nil
            return
        }
        guard attachment.id != shownImageID else { return }
        shownImageID = attachment.id
        loadTask?.cancel()
        let pixelWidth = max(view.bounds.width, 390) * (view.window?.screen.scale ?? 3) * 2
        let id = attachment.id
        loadTask = Task { @MainActor [weak self] in
            let image = await ConversationImageLoader.shared.image(for: attachment, pixelWidth: pixelWidth)
            guard let self, self.shownImageID == id, !Task.isCancelled else { return }
            if let image { self.imageView.image = image }
            self.emptyLabel.isHidden = self.imageView.image != nil
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    @objc private func toggleZoom(_ tap: UITapGestureRecognizer) {
        if scrollView.zoomScale > 1 {
            scrollView.setZoomScale(1, animated: !UIAccessibility.isReduceMotionEnabled)
        } else {
            let point = tap.location(in: imageView)
            let size = CGSize(width: scrollView.bounds.width / 2.5, height: scrollView.bounds.height / 2.5)
            scrollView.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height),
                            animated: !UIAccessibility.isReduceMotionEnabled)
        }
    }
}
#endif
