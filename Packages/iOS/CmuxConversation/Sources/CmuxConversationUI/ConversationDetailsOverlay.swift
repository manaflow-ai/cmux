#if canImport(UIKit)
import CmuxConversationCore
import UIKit

/// Conversation details, as Messages shows them on iOS 26: a material panel
/// that grows out of the header's avatar and name over the transcript, with
/// an 80 pt avatar, a 28 pt bold title and translucent inset cards. The
/// header's own back button stays on top and closes it.
///
/// Measured on iPhone 17 Pro (402 x 874, safe top 62): avatar 80 pt at the
/// safe top, title frame 33.7 pt at safe top + 84, cards inset 16 pt with
/// 52 pt rows in tertiarySystemFill, a 55 pt panel corner. Opening is a
/// ~0.4 s spring with a slight settle; closing takes ~0.2 s.
final class ConversationDetailsOverlay: UIView, UITableViewDataSource, UITableViewDelegate {
    private let store: ConversationStore
    private var info: ConversationInfo
    private let meID: String?
    private let media: ConversationSharedMediaModel
    static let photoColumns = 3
    static let photoPage = 6
    static let linkPage = 3
    private let panel = UIView()
    /// Measured: white stays white and colors stay saturated behind the
    /// panel; the gray-tinted system materials dim both, `.regular` does not.
    private let material = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private let headerView = UIView()
    private let avatar = ConversationAvatarView()
    private let titleLabel = UILabel()

    static let panelCornerRadius: CGFloat = 55
    static let avatarSize: CGFloat = 80

    init?(store: ConversationStore) {
        guard let info = store.info else { return nil }
        self.store = store
        self.info = info
        meID = store.meID
        media = ConversationSharedMediaModel(store: store, photoPage: Self.photoPage, linkPage: Self.linkPage)
        super.init(frame: .zero)
        accessibilityViewIsModal = true
        panel.clipsToBounds = true
        panel.layer.cornerCurve = .continuous
        addSubview(panel)
        panel.addSubview(material)

        let initials = info.kind == .group
            ? String(info.title.prefix(2)).uppercased()
            : (info.participants.first { $0.id != meID }?.initials ?? "")
        avatar.configure(initials: initials, colorHex: nil)
        headerView.addSubview(avatar)
        titleLabel.text = info.title
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.textAlignment = .center
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.6
        titleLabel.accessibilityTraits = .header
        titleLabel.accessibilityIdentifier = "conversation.details.title"
        headerView.addSubview(titleLabel)

        table.backgroundColor = .clear
        table.contentInsetAdjustmentBehavior = .never
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 52
        // Cards sit 16 pt from the screen edges, text 16 pt inside them.
        table.cellLayoutMarginsFollowReadableWidth = false
        table.insetsLayoutMarginsFromSafeArea = false
        table.layoutMargins = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        table.register(UITableViewCell.self, forCellReuseIdentifier: "p")
        table.register(ConversationDetailsPhotoGridCell.self, forCellReuseIdentifier: "g")
        table.accessibilityIdentifier = "conversation.details"
        table.tableHeaderView = headerView
        panel.addSubview(table)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var safeTop: CGFloat { window?.safeAreaInsets.top ?? safeAreaInsets.top }

    override func layoutSubviews() {
        super.layoutSubviews()
        material.frame = panel.bounds
        // The content is laid out in screen space and revealed by the panel.
        table.bounds.size = bounds.size
        table.center = CGPoint(x: bounds.midX - panel.frame.minX, y: bounds.midY - panel.frame.minY + contentDrop)
        let top = safeTop
        let headerHeight = top + Self.avatarSize + 4 + 33.7 + 20
        if headerView.frame.size != CGSize(width: bounds.width, height: headerHeight) {
            headerView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
            table.tableHeaderView = headerView
        }
        avatar.frame = CGRect(x: (bounds.width - Self.avatarSize) / 2, y: top, width: Self.avatarSize, height: Self.avatarSize)
        titleLabel.frame = CGRect(x: 60, y: top + Self.avatarSize + 4, width: bounds.width - 120, height: 33.7)
        table.contentInset.bottom = safeAreaInsets.bottom + 16
    }

    /// Vertical offset of the content while the panel springs open.
    private var contentDrop: CGFloat = 0

    // MARK: Presentation

    /// Grows the panel out of `source` (the header's avatar and name, in this
    /// view's coordinates).
    func present(from source: CGRect) {
        panel.frame = source
        panel.layer.cornerRadius = min(source.width, source.height) / 2
        contentDrop = 60
        table.alpha = 0
        layoutIfNeeded()
        let spring = UISpringTimingParameters(dampingRatio: 0.82, initialVelocity: .zero)
        let animator = UIViewPropertyAnimator(duration: 0.42, timingParameters: spring)
        animator.addAnimations {
            self.panel.frame = self.bounds
            self.panel.layer.cornerRadius = Self.panelCornerRadius
            self.contentDrop = 0
            self.setNeedsLayout()
            self.layoutIfNeeded()
        }
        animator.addAnimations({ self.table.alpha = 1 }, delayFactor: 0)
        animator.startAnimation()
        UIAccessibility.post(notification: .screenChanged, argument: titleLabel)
    }

    /// Shrinks the panel back into `source`, then removes itself.
    func dismiss(to source: CGRect, completion: @escaping () -> Void) {
        let animator = UIViewPropertyAnimator(duration: 0.24, dampingRatio: 1) {
            self.panel.frame = source
            self.panel.layer.cornerRadius = min(source.width, source.height) / 2
            self.contentDrop = 40
            self.table.alpha = 0
            self.panel.alpha = 0
            self.setNeedsLayout()
            self.layoutIfNeeded()
        }
        animator.addCompletion { _ in
            self.removeFromSuperview()
            completion()
        }
        animator.startAnimation()
    }

    // MARK: Store

    /// Forwarded by the conversation controller: list state, photos and links stay live.
    func storeDidChange(_ change: ConversationStoreChange) {
        switch change {
        case .typing, .draft, .readState:
            return
        case .live, .reset:
            media.invalidate()
        default:
            break
        }
        if let info = store.info { self.info = info }
        media.storeDidChange()
        table.reloadData()
    }

    // MARK: Table

    private enum Section {
        case toggles
        case members
        case photos
        case links
    }

    private var sections: [Section] {
        var sections: [Section] = [.toggles]
        if info.kind == .group { sections.append(.members) }
        if !media.photos.isEmpty { sections.append(.photos) }
        if !media.links.isEmpty { sections.append(.links) }
        return sections
    }

    /// Messages offers Send Read Receipts per conversation only one to one.
    private var toggleCount: Int { info.kind == .group ? 1 : 2 }

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch sections[section] {
        case .toggles: return toggleCount
        case .members: return info.participants.count
        case .photos: return 1 + (media.hasMore(.photos) ? 1 : 0)
        case .links: return media.links.count + (media.hasMore(.links) ? 1 : 0)
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch sections[section] {
        case .toggles: return nil
        case .members:
            return String(format: String(localized: "conversation.info.members", defaultValue: "%d Members", bundle: .module), info.participants.count)
        // PHOTOS_MENU_ITEM_TITLE / LINKS
        case .photos: return String(localized: "conversation.details.photos", defaultValue: "Photos", bundle: .module)
        case .links: return String(localized: "conversation.details.links", defaultValue: "Links", bundle: .module)
        }
    }

    private var photoGridWidth: CGFloat { max(0, table.bounds.width - 32 - 2 * ConversationDetailsPhotoGridCell.padding) }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if sections[indexPath.section] == .photos, indexPath.row == 0 {
            return ConversationDetailsPhotoGridCell.height(count: media.photos.count, columns: Self.photoColumns, width: photoGridWidth)
        }
        // A link row carries its site under the title.
        if sections[indexPath.section] == .links, !isSeeAll(indexPath) { return UITableView.automaticDimension }
        return 52
    }

    private func isSeeAll(_ indexPath: IndexPath) -> Bool {
        switch sections[indexPath.section] {
        case .photos: return indexPath.row == 1
        case .links: return indexPath.row == media.links.count
        default: return false
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let section = sections[indexPath.section]
        if section == .photos, indexPath.row == 0 {
            let cell = tableView.dequeueReusableCell(withIdentifier: "g", for: indexPath) as! ConversationDetailsPhotoGridCell
            cell.configure(photos: media.photos, columns: Self.photoColumns)
            cell.backgroundConfiguration = Self.cardBackground
            cell.selectionStyle = .none
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: "p", for: indexPath)
        var content = cell.defaultContentConfiguration()
        cell.accessoryView = nil
        cell.selectionStyle = .none
        cell.accessibilityIdentifier = nil
        if isSeeAll(indexPath) {
            // SEARCH_SHOW_MORE
            content.text = String(localized: "conversation.details.seeAll", defaultValue: "See All", bundle: .module)
            content.textProperties.color = .tintColor
            cell.accessibilityIdentifier = section == .photos ? "conversation.details.photos.more" : "conversation.details.links.more"
            cell.selectionStyle = .default
        } else {
            switch section {
            case .toggles:
                let toggle = UISwitch()
                if indexPath.row == 0 {
                    // DETAILS_VIEW_HIDE_ALERTS_TOGGLE_TITLE
                    content.text = String(localized: "conversation.details.hideAlerts", defaultValue: "Hide Alerts", bundle: .module)
                    toggle.isOn = info.listState.muted
                    toggle.addTarget(self, action: #selector(alertsToggled(_:)), for: .valueChanged)
                    toggle.accessibilityIdentifier = "conversation.details.hideAlerts"
                } else {
                    // READ_RECEIPTS
                    content.text = String(localized: "conversation.details.readReceipts", defaultValue: "Send Read Receipts", bundle: .module)
                    toggle.isOn = info.listState.sendReadReceipts
                    toggle.addTarget(self, action: #selector(receiptsToggled(_:)), for: .valueChanged)
                    toggle.accessibilityIdentifier = "conversation.details.readReceipts"
                }
                cell.accessoryView = toggle
            case .members:
                let participant = info.participants[indexPath.row]
                content.text = participant.isMe ? String(localized: "conversation.reaction.you", defaultValue: "You", bundle: .module) : participant.name
            case .links:
                let link = media.links[indexPath.row]
                content = .subtitleCell()
                content.text = link.preview.title ?? link.preview.domain
                content.secondaryText = link.preview.domain
                content.secondaryTextProperties.color = .secondaryLabel
                content.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)
                content.textToSecondaryTextVerticalPadding = 2
                content.textProperties.numberOfLines = 1
                cell.selectionStyle = .default
            case .photos:
                break
            }
        }
        cell.contentConfiguration = content
        cell.backgroundConfiguration = Self.cardBackground
        return cell
    }

    /// Messages' cards are translucent over the panel's material.
    private static var cardBackground: UIBackgroundConfiguration {
        var background = UIBackgroundConfiguration.listGroupedCell()
        background.backgroundColor = .tertiarySystemFill
        return background
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let section = sections[indexPath.section]
        if isSeeAll(indexPath) {
            media.showMore(section == .photos ? .photos : .links)
            tableView.reloadData()
        } else if section == .links {
            UIApplication.shared.open(media.links[indexPath.row].preview.url)
        }
    }

    @objc private func alertsToggled(_ sender: UISwitch) {
        store.updateListState(.init(muted: sender.isOn))
    }

    @objc private func receiptsToggled(_ sender: UISwitch) {
        store.updateListState(.init(sendReadReceipts: sender.isOn))
    }
}

/// The Photos section's grid: square thumbnails, three across.
final class ConversationDetailsPhotoGridCell: UITableViewCell {
    static let padding: CGFloat = 8
    static let gap: CGFloat = 4
    private var imageViews: [UIImageView] = []
    private var tasks: [Task<Void, Never>] = []
    private var columns = 3

    static func height(count: Int, columns: Int, width: CGFloat) -> CGFloat {
        let rows = CGFloat((count + columns - 1) / columns)
        let side = floor((width - gap * CGFloat(columns - 1)) / CGFloat(columns))
        return rows * side + max(0, rows - 1) * gap + 2 * padding
    }

    func configure(photos: [ConversationSharedPhoto], columns: Int) {
        self.columns = columns
        tasks.forEach { $0.cancel() }
        tasks = []
        while imageViews.count < photos.count {
            let view = UIImageView()
            view.contentMode = .scaleAspectFill
            view.clipsToBounds = true
            view.layer.cornerRadius = 6
            view.layer.cornerCurve = .continuous
            view.backgroundColor = .quaternarySystemFill
            view.isAccessibilityElement = true
            view.accessibilityTraits = .image
            view.accessibilityLabel = String(localized: "conversation.quote.photo", defaultValue: "Photo", bundle: .module)
            contentView.addSubview(view)
            imageViews.append(view)
        }
        while imageViews.count > photos.count { imageViews.removeLast().removeFromSuperview() }
        let pixelWidth = 200 * (window?.screen.scale ?? 3)
        for (view, photo) in zip(imageViews, photos) {
            let attachment = photo.attachment
            if let cached = ConversationImageLoader.shared.cachedImage(for: attachment, pixelWidth: pixelWidth) {
                view.image = cached
                continue
            }
            view.image = nil
            tasks.append(Task { [weak view] in
                let image = await ConversationImageLoader.shared.image(for: attachment, pixelWidth: pixelWidth)
                guard !Task.isCancelled else { return }
                view?.image = image
            })
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = contentView.bounds.width - 2 * Self.padding
        let side = floor((width - Self.gap * CGFloat(columns - 1)) / CGFloat(columns))
        for (index, view) in imageViews.enumerated() {
            let column = CGFloat(index % columns), row = CGFloat(index / columns)
            view.frame = CGRect(x: Self.padding + column * (side + Self.gap), y: Self.padding + row * (side + Self.gap), width: side, height: side)
        }
    }
}
#endif
