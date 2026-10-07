#if os(macOS)
import AppKit
import CmuxConversationCore

/// ChatKit's Mac strings for the details panel (key in each comment).
enum MacDetailsStrings {
    // DETAILS
    static var details: String { String(localized: "conversation.details.title", defaultValue: "Details", bundle: .module) }
    // SHOW_DETAILS / HIDE_DETAILS_VIEW (menu item and button tooltip)
    static var showDetails: String { String(localized: "conversation.details.show", defaultValue: "Show Details", bundle: .module) }
    static var hideDetails: String { String(localized: "conversation.details.hide", defaultValue: "Hide Details", bundle: .module) }
    // SHOW_CONVERSATION_DETAILS_AX_VALUE / HIDE_CONVERSATION_DETAILS_AX_VALUE
    static var showDetailsAXValue: String {
        String(localized: "conversation.details.show.axValue", defaultValue: "Show Conversation Details", bundle: .module)
    }
    static var hideDetailsAXValue: String {
        String(localized: "conversation.details.hide.axValue", defaultValue: "Hide Conversation Details", bundle: .module)
    }
    // DETAILS_VIEW_HIDE_ALERTS_TOGGLE_TITLE
    static var hideAlerts: String { String(localized: "conversation.details.hideAlerts", defaultValue: "Hide Alerts", bundle: .module) }
    // READ_RECEIPTS
    static var readReceipts: String { String(localized: "conversation.details.readReceipts", defaultValue: "Send Read Receipts", bundle: .module) }
    // PHOTOS_MENU_ITEM_TITLE
    static var photos: String { String(localized: "conversation.details.photos", defaultValue: "Photos", bundle: .module) }
    // LINKS
    static var links: String { String(localized: "conversation.details.links", defaultValue: "Links", bundle: .module) }
    // SEARCH_SHOW_MORE_MAC
    static var showMore: String { String(localized: "conversation.details.showMore", defaultValue: "Show More", bundle: .module) }
    // DETAILS_VIEW_GROUP_COUNT_TEXT ("%lu PEOPLE")
    static func people(_ count: Int) -> String {
        count == 1
            ? String(format: String(localized: "conversation.details.person", defaultValue: "%ld PERSON", bundle: .module), count)
            : String(format: String(localized: "conversation.details.people", defaultValue: "%ld PEOPLE", bundle: .module), count)
    }
    // DRAFT_CONVERSATION_LIST_SUMMARY
    static func draftSummary(_ text: String) -> String {
        String(format: String(localized: "conversation.sidebar.draft", defaultValue: "Draft: %@", bundle: .module), text)
    }
    // ACCESSIBILITY_GROUP_TYPING_LIST_SINGULAR / _PLURAL
    static func typing(_ names: [String]) -> String {
        let list = ListFormatter.localizedString(byJoining: names)
        return names.count > 1
            ? String(format: String(localized: "conversation.sidebar.typing.plural", defaultValue: "%@ are typing", bundle: .module), list)
            : String(format: String(localized: "conversation.sidebar.typing.singular", defaultValue: "%@ is typing", bundle: .module), list)
    }
}

/// Where the details panel lives (the window's inspector). The conversation
/// controller's `toggleConversationDetails(_:)` goes through it.
@MainActor
protocol MacConversationDetailsHost: AnyObject {
    var isConversationDetailsShown: Bool { get }
    func toggleConversationDetails()
}

/// Messages' details panel for one conversation: avatar and name, Hide
/// Alerts and Send Read Receipts switches, the members of a group, then the
/// Photos and Links shared in it with "Show More". Calls, FaceTime, Mail and
/// Documents are omitted: the product has none of them.
@MainActor
final class MacConversationDetailsViewController: NSViewController {
    let store: ConversationStore
    /// Hide Alerts goes through the sidebar's list action path.
    var onToggleAlerts: (() -> Void)?
    let media: ConversationSharedMediaModel

    private let scrollView = NSScrollView()
    private let content = MacFlippedView()
    private let avatar = MacAvatarView()
    private let nameLabel = makeMacLabel()
    private let toggleCard = MacFlippedView()
    private let alertsLabel = makeMacLabel()
    private let alertsSwitch = NSSwitch()
    private let receiptsLabel = makeMacLabel()
    private let receiptsSwitch = NSSwitch()
    private let toggleSeparator = NSBox()
    private let membersHeader = makeMacLabel()
    private let membersCard = MacFlippedView()
    private var memberRows: [(avatar: MacAvatarView, name: NSTextField)] = []
    private let photosHeader = makeMacLabel()
    private let photosMore = NSButton()
    private var photoViews: [MacDetailsPhotoView] = []
    private let linksHeader = makeMacLabel()
    private let linksMore = NSButton()
    private let linksCard = MacFlippedView()
    private var linkViews: [MacDetailsLinkView] = []
    private var needsRebuild = true

    /// Measured layout is unavailable (macOS Messages could not be captured
    /// on the fleet); these follow the iOS panel's proportions at Mac scale.
    static let avatarSize: CGFloat = 64
    static let inset: CGFloat = 16
    static let rowHeight: CGFloat = 36
    static let photoColumns = 3
    static let photoGap: CGFloat = 4
    static let photoPage = 6
    static let linkPage = 3

    init(store: ConversationStore) {
        self.store = store
        media = ConversationSharedMediaModel(store: store, photoPage: Self.photoPage, linkPage: Self.linkPage)
        super.init(nibName: nil, bundle: nil)
        store.addObserver { [weak self] change in self?.storeDidChange(change) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = MacFlippedView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.autoresizingMask = [.width, .height]
        scrollView.frame = root.bounds
        scrollView.documentView = content
        root.addSubview(scrollView)
        root.setAccessibilityIdentifier("conversation.details")
        root.setAccessibilityRole(.group)
        root.setAccessibilityLabel(MacDetailsStrings.details)

        nameLabel.font = .systemFont(ofSize: 17, weight: .bold)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setAccessibilityIdentifier("conversation.details.name")
        for card in [toggleCard, membersCard, linksCard] {
            card.wantsLayer = true
            card.layer?.cornerRadius = 10
            card.layer?.cornerCurve = .continuous
        }
        alertsLabel.stringValue = MacDetailsStrings.hideAlerts
        receiptsLabel.stringValue = MacDetailsStrings.readReceipts
        for (label, toggle, id) in [(alertsLabel, alertsSwitch, "hideAlerts"), (receiptsLabel, receiptsSwitch, "readReceipts")] {
            label.font = .systemFont(ofSize: 13)
            toggle.controlSize = .small
            toggle.target = self
            toggle.action = toggle === alertsSwitch ? #selector(alertsToggled) : #selector(receiptsToggled)
            toggle.setAccessibilityLabel(label.stringValue)
            toggle.setAccessibilityIdentifier("conversation.details.\(id)")
            toggleCard.addSubview(label)
            toggleCard.addSubview(toggle)
        }
        toggleSeparator.boxType = .separator
        toggleCard.addSubview(toggleSeparator)
        for header in [membersHeader, photosHeader, linksHeader] {
            header.font = .systemFont(ofSize: 11, weight: .semibold)
            header.textColor = .secondaryLabelColor
        }
        photosHeader.stringValue = MacDetailsStrings.photos
        linksHeader.stringValue = MacDetailsStrings.links
        for (button, id) in [(photosMore, "photos"), (linksMore, "links")] {
            button.title = MacDetailsStrings.showMore
            button.isBordered = false
            button.font = .systemFont(ofSize: 11, weight: .regular)
            button.contentTintColor = .controlAccentColor
            button.attributedTitle = NSAttributedString(string: MacDetailsStrings.showMore, attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.controlAccentColor,
            ])
            button.target = self
            button.action = button === photosMore ? #selector(showMorePhotos) : #selector(showMoreLinks)
            button.setAccessibilityIdentifier("conversation.details.\(id).more")
        }
        for view in [avatar, nameLabel, toggleCard, membersHeader, membersCard, photosHeader, photosMore, linksHeader, linksMore, linksCard] as [NSView] {
            content.addSubview(view)
        }
        view = root
        updateColors()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        rebuildIfNeeded()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutContent()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        updateColors()
    }

    private func updateColors() {
        let fill = resolved(NSColor.labelColor.withAlphaComponent(0.05), in: view)
        for card in [toggleCard, membersCard, linksCard] { card.layer?.backgroundColor = fill }
    }

    // MARK: Store

    private func storeDidChange(_ change: ConversationStoreChange) {
        switch change {
        case .typing, .draft, .readState:
            return
        case .live, .reset:
            // In-place updates (an unsend, a card that finished loading).
            media.invalidate()
        default:
            break
        }
        media.storeDidChange()
        needsRebuild = true
        if isViewLoaded, view.window != nil { rebuildIfNeeded() }
    }

    @objc private func alertsToggled() {
        if let onToggleAlerts {
            onToggleAlerts()
        } else {
            store.updateListState(.init(muted: alertsSwitch.state == .on))
        }
    }

    @objc private func receiptsToggled() {
        store.updateListState(.init(sendReadReceipts: receiptsSwitch.state == .on))
    }

    @objc private func showMorePhotos() {
        media.showMore(.photos)
        needsRebuild = true
        rebuildIfNeeded()
    }

    @objc private func showMoreLinks() {
        media.showMore(.links)
        needsRebuild = true
        rebuildIfNeeded()
    }

    // MARK: Content

    private var isGroup: Bool { store.info?.kind == .group }

    private var others: [ConversationParticipant] {
        store.info?.participants.filter { $0.id != store.meID } ?? []
    }

    func rebuildIfNeeded() {
        guard isViewLoaded, needsRebuild else { return }
        needsRebuild = false
        let info = store.info
        nameLabel.stringValue = info?.title ?? ""
        if isGroup {
            avatar.initials = String((info?.title ?? "").prefix(2)).uppercased()
            avatar.colorHex = nil
        } else {
            avatar.initials = others.first?.initials ?? ""
            avatar.colorHex = others.first?.colorHex
        }
        let state = store.listState
        alertsSwitch.state = state.muted ? .on : .off
        receiptsSwitch.state = state.sendReadReceipts ? .on : .off
        // Messages offers Send Read Receipts per conversation only one to one.
        receiptsLabel.isHidden = isGroup
        receiptsSwitch.isHidden = isGroup
        toggleSeparator.isHidden = isGroup

        memberRows.forEach { $0.avatar.removeFromSuperview(); $0.name.removeFromSuperview() }
        memberRows = []
        membersHeader.isHidden = !isGroup
        membersCard.isHidden = !isGroup
        if isGroup {
            membersHeader.stringValue = MacDetailsStrings.people(others.count)
            memberRows = others.map { participant in
                let avatar = MacAvatarView()
                avatar.initials = participant.initials
                avatar.colorHex = participant.colorHex
                let name = makeMacLabel()
                name.stringValue = participant.name
                name.font = .systemFont(ofSize: 13)
                name.lineBreakMode = .byTruncatingTail
                membersCard.addSubview(avatar)
                membersCard.addSubview(name)
                return (avatar, name)
            }
        }

        let photos = media.photos
        while photoViews.count < photos.count {
            let view = MacDetailsPhotoView()
            content.addSubview(view)
            photoViews.append(view)
        }
        while photoViews.count > photos.count { photoViews.removeLast().removeFromSuperview() }
        for (view, photo) in zip(photoViews, photos) { view.photo = photo }
        photosHeader.isHidden = photos.isEmpty
        photosMore.isHidden = photos.isEmpty || !media.hasMore(.photos)

        let links = media.links
        while linkViews.count < links.count {
            let view = MacDetailsLinkView()
            linksCard.addSubview(view)
            linkViews.append(view)
        }
        while linkViews.count > links.count { linkViews.removeLast().removeFromSuperview() }
        for (view, link) in zip(linkViews, links) { view.link = link }
        linksHeader.isHidden = links.isEmpty
        linksCard.isHidden = links.isEmpty
        linksMore.isHidden = links.isEmpty || !media.hasMore(.links)
        layoutContent()
    }

    private func layoutContent() {
        guard isViewLoaded else { return }
        let width = scrollView.contentSize.width
        let inset = Self.inset
        let inner = width - inset * 2
        var y: CGFloat = 20
        avatar.frame = CGRect(x: (width - Self.avatarSize) / 2, y: y, width: Self.avatarSize, height: Self.avatarSize)
        y += Self.avatarSize + 8
        nameLabel.frame = CGRect(x: inset, y: y, width: inner, height: 22)
        y += 22 + 16

        let toggleRows: CGFloat = isGroup ? 1 : 2
        toggleCard.frame = CGRect(x: inset, y: y, width: inner, height: toggleRows * Self.rowHeight)
        func placeToggle(_ label: NSTextField, _ toggle: NSSwitch, row: CGFloat) {
            let size = toggle.fittingSize
            toggle.frame = CGRect(x: inner - 12 - size.width, y: row * Self.rowHeight + (Self.rowHeight - size.height) / 2, width: size.width, height: size.height)
            label.frame = CGRect(x: 12, y: row * Self.rowHeight + (Self.rowHeight - 17) / 2, width: toggle.frame.minX - 20, height: 17)
        }
        placeToggle(alertsLabel, alertsSwitch, row: 0)
        placeToggle(receiptsLabel, receiptsSwitch, row: 1)
        toggleSeparator.frame = CGRect(x: 12, y: Self.rowHeight - 0.5, width: inner - 12, height: 1)
        y = toggleCard.frame.maxY + 20

        if isGroup {
            membersHeader.frame = CGRect(x: inset + 12, y: y, width: inner - 12, height: 14)
            y += 14 + 6
            membersCard.frame = CGRect(x: inset, y: y, width: inner, height: CGFloat(memberRows.count) * Self.rowHeight)
            for (index, row) in memberRows.enumerated() {
                let top = CGFloat(index) * Self.rowHeight
                row.avatar.frame = CGRect(x: 12, y: top + (Self.rowHeight - 24) / 2, width: 24, height: 24)
                row.name.frame = CGRect(x: 44, y: top + (Self.rowHeight - 17) / 2, width: inner - 56, height: 17)
            }
            y = membersCard.frame.maxY + 20
        }

        if !photoViews.isEmpty {
            placeHeader(photosHeader, more: photosMore, y: y, inset: inset, inner: inner)
            y += 14 + 6
            let columns = CGFloat(Self.photoColumns)
            let side = floor((inner - Self.photoGap * (columns - 1)) / columns)
            for (index, view) in photoViews.enumerated() {
                let column = CGFloat(index % Self.photoColumns), row = CGFloat(index / Self.photoColumns)
                view.frame = CGRect(x: inset + column * (side + Self.photoGap), y: y + row * (side + Self.photoGap), width: side, height: side)
            }
            let rows = CGFloat((photoViews.count + Self.photoColumns - 1) / Self.photoColumns)
            y += rows * side + (rows - 1) * Self.photoGap + 20
        }

        if !linkViews.isEmpty {
            placeHeader(linksHeader, more: linksMore, y: y, inset: inset, inner: inner)
            y += 14 + 6
            let height = MacDetailsLinkView.height
            linksCard.frame = CGRect(x: inset, y: y, width: inner, height: CGFloat(linkViews.count) * height)
            for (index, view) in linkViews.enumerated() {
                view.frame = CGRect(x: 0, y: CGFloat(index) * height, width: inner, height: height)
                view.showsSeparator = index < linkViews.count - 1
            }
            y = linksCard.frame.maxY + 20
        }
        content.frame = CGRect(x: 0, y: 0, width: width, height: max(y, scrollView.contentSize.height))
    }

    private func placeHeader(_ header: NSTextField, more: NSButton, y: CGFloat, inset: CGFloat, inner: CGFloat) {
        let moreWidth = more.isHidden ? 0 : ceil(more.fittingSize.width)
        more.frame = CGRect(x: inset + inner - moreWidth - 4, y: y - 2, width: moreWidth, height: 18)
        header.frame = CGRect(x: inset + 12, y: y, width: inner - 24 - moreWidth, height: 14)
    }

    // MARK: Lab

    /// What the panel shows, for lab drivers.
    func labSnapshot() -> [String: Any] {
        rebuildIfNeeded()
        return [
            "name": nameLabel.stringValue,
            "hideAlerts": alertsSwitch.state == .on,
            "readReceipts": receiptsSwitch.isHidden ? NSNull() : (receiptsSwitch.state == .on) as Any,
            "members": memberRows.map(\.name.stringValue),
            "membersHeader": membersHeader.isHidden ? "" : membersHeader.stringValue,
            "photos": photoViews.compactMap(\.photo?.messageID),
            "photosMore": !photosMore.isHidden,
            "links": linkViews.compactMap { $0.link?.preview.url.absoluteString },
            "linksMore": !linksMore.isHidden,
            "loadingMore": media.isLoadingMore,
        ]
    }

    func labPress(_ control: String) -> Bool {
        rebuildIfNeeded()
        switch control {
        case "hideAlerts":
            alertsSwitch.performClick(nil)
        case "readReceipts":
            guard !receiptsSwitch.isHidden else { return false }
            receiptsSwitch.performClick(nil)
        case "photosMore":
            guard !photosMore.isHidden else { return false }
            photosMore.performClick(nil)
        case "linksMore":
            guard !linksMore.isHidden else { return false }
            linksMore.performClick(nil)
        default:
            return false
        }
        return true
    }
}

/// A square photo thumbnail; a click opens Quick Look.
final class MacDetailsPhotoView: MacFlippedView {
    private let imageLayer = CALayer()
    private var task: Task<Void, Never>?

    var photo: ConversationSharedPhoto? {
        didSet {
            guard photo?.id != oldValue?.id else { return }
            load()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        layer?.addSublayer(imageLayer)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(String(localized: "conversation.quote.photo", defaultValue: "Photo", bundle: .module))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
    }

    private func load() {
        task?.cancel()
        imageLayer.contents = nil
        guard let attachment = photo?.attachment else { return }
        if let cached = MacImageLoader.shared.cached(attachment) {
            setImage(cached)
            return
        }
        task = Task { [weak self] in
            let image = await MacImageLoader.shared.image(for: attachment)
            guard !Task.isCancelled, let self, self.photo?.attachment.id == attachment.id else { return }
            self.setImage(image)
        }
    }

    /// Aspect fill: the layer shows the image cropped to the square.
    private func setImage(_ image: NSImage?) {
        imageLayer.contents = image?.layerContents(forContentsScale: window?.backingScaleFactor ?? 2)
    }

    override func mouseUp(with event: NSEvent) {
        guard let attachment = photo?.attachment, let image = MacImageLoader.shared.cached(attachment) else { return }
        MacPhotoQuickLook.shared.show(attachment, image: image, from: self, rect: bounds)
    }

    override func accessibilityPerformPress() -> Bool {
        mouseUp(with: NSEvent())
        return true
    }
}

/// A shared link: its icon (or the card image), title and site; a click opens it.
final class MacDetailsLinkView: MacFlippedView {
    static let height: CGFloat = 52
    private let icon = NSImageView()
    private let title = makeMacLabel()
    private let site = makeMacLabel()
    private let separator = NSBox()
    private var task: Task<Void, Never>?
    var showsSeparator = true { didSet { separator.isHidden = !showsSeparator } }

    var link: ConversationSharedLink? {
        didSet {
            guard link != oldValue, let link else { return }
            let preview = link.preview
            title.stringValue = preview.title ?? preview.domain
            site.stringValue = preview.domain
            setAccessibilityLabel("\(title.stringValue), \(site.stringValue)")
            loadIcon(preview.icon ?? preview.image)
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 6
        icon.layer?.masksToBounds = true
        icon.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        site.font = .systemFont(ofSize: 11)
        site.textColor = .secondaryLabelColor
        site.lineBreakMode = .byTruncatingTail
        separator.boxType = .separator
        for view in [icon, title, site, separator] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.link)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        icon.frame = CGRect(x: 12, y: (bounds.height - 32) / 2, width: 32, height: 32)
        title.frame = CGRect(x: 54, y: 9, width: bounds.width - 66, height: 17)
        site.frame = CGRect(x: 54, y: 27, width: bounds.width - 66, height: 15)
        separator.frame = CGRect(x: 54, y: bounds.height - 1, width: bounds.width - 54, height: 1)
    }

    private func loadIcon(_ image: ConversationLinkPreview.Image?) {
        task?.cancel()
        icon.image = NSImage(systemSymbolName: "safari", accessibilityDescription: nil)
        guard let url = image?.url else { return }
        task = Task { [weak self] in
            guard let data = try? await URLSession.shared.data(from: url).0, !Task.isCancelled, let loaded = NSImage(data: data) else { return }
            self?.icon.image = loaded
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let url = link?.preview.url { NSWorkspace.shared.open(url) }
    }

    override func accessibilityPerformPress() -> Bool {
        if let url = link?.preview.url { NSWorkspace.shared.open(url) }
        return true
    }
}

/// The typing indicator in a sidebar row's preview: a small gray bubble
/// whose three dots pulse in turn, as Messages shows while someone types.
final class MacListTypingIndicator: MacFlippedView {
    private let bubble = CALayer()
    private let replicator = CAReplicatorLayer()
    private let dot = CALayer()
    static let size = CGSize(width: 34, height: 20)
    private static let dotDiameter: CGFloat = 5
    private static let dotSpacing: CGFloat = 7.5

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.addSublayer(bubble)
        dot.bounds = CGRect(x: 0, y: 0, width: Self.dotDiameter, height: Self.dotDiameter)
        dot.position = CGPoint(x: Self.dotDiameter / 2, y: Self.dotDiameter / 2)
        dot.cornerRadius = Self.dotDiameter / 2
        dot.opacity = 0.25
        replicator.instanceCount = 3
        replicator.instanceTransform = CATransform3DMakeTranslation(Self.dotSpacing, 0, 0)
        replicator.instanceDelay = 0.25
        replicator.addSublayer(dot)
        bubble.addSublayer(replicator)
        setAccessibilityIdentifier("conversation.sidebar.typing")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bubble.frame = CGRect(origin: .zero, size: Self.size)
        bubble.cornerRadius = Self.size.height / 2
        bubble.backgroundColor = resolved(MacConversationTheme.incomingBubble, in: self)
        let dotsWidth = Self.dotDiameter + 2 * Self.dotSpacing
        replicator.frame = CGRect(x: (Self.size.width - dotsWidth) / 2, y: (Self.size.height - Self.dotDiameter) / 2, width: dotsWidth, height: Self.dotDiameter)
        dot.backgroundColor = resolved(.labelColor, in: self)
        CATransaction.commit()
        if dot.animation(forKey: "dot") == nil {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.25
            fade.toValue = 0.6
            fade.duration = 0.5
            fade.autoreverses = true
            fade.repeatCount = .infinity
            fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.757, 0.015, 0.58, 1)
            dot.add(fade, forKey: "dot")
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }
}
#endif
