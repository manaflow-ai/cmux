#if canImport(UIKit)
import CmuxConversationCore
import UIKit

/// The details' Info page (Messages' DetailsInfoTabView): inset cards on
/// the backdrop, under the floating header. A group lists its members as
/// 90 pt avatars, three across; then Hide Alerts (and Send Read Receipts
/// one to one), Photos and Links.
///
/// Measured in MobileSMS (iOS 26.5, 440 pt): cards 20 pt from the edges in
/// the tertiary fill, 52 pt rows, 20 pt between sections.
final class ConversationDetailsInfoPage: NSObject, UITableViewDataSource, UITableViewDelegate {
    private let store: ConversationStore
    private var info: ConversationInfo
    private let meID: String?
    private let media: ConversationSharedMediaModel
    static let photoColumns = 3
    static let photoPage = 6
    static let linkPage = 3
    let table = UITableView(frame: .zero, style: .insetGrouped)
    private let spacer = UIView()
    var onScroll: (() -> Void)?

    init(store: ConversationStore) {
        self.store = store
        self.info = store.info ?? ConversationInfo(id: "", title: "", kind: .direct, participants: [])
        meID = store.meID
        media = ConversationSharedMediaModel(store: store, photoPage: Self.photoPage, linkPage: Self.linkPage)
        super.init()
        table.backgroundColor = .clear
        table.contentInsetAdjustmentBehavior = .never
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 52
        table.sectionHeaderTopPadding = 0
        table.cellLayoutMarginsFollowReadableWidth = false
        table.insetsLayoutMarginsFromSafeArea = false
        table.layoutMargins = UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
        table.register(UITableViewCell.self, forCellReuseIdentifier: "p")
        table.register(ConversationDetailsPhotoGridCell.self, forCellReuseIdentifier: "g")
        table.register(ConversationDetailsMembersCell.self, forCellReuseIdentifier: "m")
        table.accessibilityIdentifier = "conversation.details"
        table.tableHeaderView = spacer
    }

    /// The other members, as the group grid shows them.
    private var members: [ConversationParticipant] {
        info.participants.filter { !$0.isMe && $0.id != meID }
    }

    /// Where the cards start: under the header at rest.
    func setHeaderHeight(_ height: CGFloat, bottomInset: CGFloat) {
        if spacer.frame.height != height || spacer.frame.width != table.bounds.width {
            spacer.frame = CGRect(x: 0, y: 0, width: table.bounds.width, height: height)
            table.tableHeaderView = spacer
        }
        table.contentInset.bottom = bottomInset + 20
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        onScroll?()
    }

    // Sections are 20 pt apart, with no titles above the cards.
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        tableView.dataSource?.tableView?(tableView, titleForHeaderInSection: section) == nil ? (section == 0 ? .leastNonzeroMagnitude : 20) : UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat { .leastNonzeroMagnitude }

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
        var sections: [Section] = []
        if info.kind == .group { sections.append(.members) }
        sections.append(.toggles)
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
        case .members: return 1
        case .photos: return 1 + (media.hasMore(.photos) ? 1 : 0)
        case .links: return media.links.count + (media.hasMore(.links) ? 1 : 0)
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch sections[section] {
        case .toggles, .members: return nil
        // PHOTOS_MENU_ITEM_TITLE / LINKS
        case .photos: return String(localized: "conversation.details.photos", defaultValue: "Photos", bundle: .module)
        case .links: return String(localized: "conversation.details.links", defaultValue: "Links", bundle: .module)
        }
    }

    private var photoGridWidth: CGFloat { max(0, table.bounds.width - 32 - 2 * ConversationDetailsPhotoGridCell.padding) }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if sections[indexPath.section] == .members {
            return ConversationDetailsMembersCell.height(count: members.count)
        }
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
        if section == .members {
            let cell = tableView.dequeueReusableCell(withIdentifier: "m", for: indexPath) as! ConversationDetailsMembersCell
            cell.configure(members: members)
            return cell
        }
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
                break  // its own cell
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

#if canImport(UIKit)
/// A group's members, on the backdrop rather than in a card: 90 pt avatars
/// three across, 141 pt apart, each with its name under it (Messages'
/// details, iPhone 17 Pro Max: rows 146 pt apart).
final class ConversationDetailsMembersCell: UITableViewCell {
    static let avatarSize: CGFloat = 90
    static let columnPitch: CGFloat = 141
    static let rowPitch: CGFloat = 146
    static let columns = 3
    private var tiles: [(avatar: ConversationAvatarView, name: UILabel)] = []

    static func height(count: Int) -> CGFloat {
        CGFloat((count + columns - 1) / columns) * rowPitch
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        var clear = UIBackgroundConfiguration.clear()
        clear.backgroundColor = .clear
        backgroundConfiguration = clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(members: [ConversationParticipant]) {
        tiles.forEach { $0.avatar.removeFromSuperview(); $0.name.removeFromSuperview() }
        tiles = members.map { member in
            let avatar = ConversationAvatarView()
            avatar.configure(initials: member.initials, colorHex: nil)
            let name = UILabel()
            name.text = member.name
            name.font = .systemFont(ofSize: 15)
            name.textColor = .label
            name.textAlignment = .center
            name.lineBreakMode = .byTruncatingTail
            name.isAccessibilityElement = true
            contentView.addSubview(avatar)
            contentView.addSubview(name)
            return (avatar, name)
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Columns are centered on the screen, which the inset card is too.
        let mid = contentView.bounds.midX
        for (index, tile) in tiles.enumerated() {
            let column = CGFloat(index % Self.columns) - 1
            let row = CGFloat(index / Self.columns)
            let x = mid + column * Self.columnPitch
            tile.avatar.frame = CGRect(x: x - Self.avatarSize / 2, y: row * Self.rowPitch, width: Self.avatarSize, height: Self.avatarSize)
            tile.name.frame = CGRect(x: x - Self.columnPitch / 2 + 4, y: tile.avatar.frame.maxY + 3, width: Self.columnPitch - 8, height: 18)
        }
    }
}

/// The details' Backgrounds page: the background categories as circles
/// with their names, four across; choosing one opens the editor on it.
final class ConversationDetailsBackgroundsPage: NSObject, UIScrollViewDelegate {
    let scroll = UIScrollView()
    private var tiles: [(kind: ConversationBackground.Kind?, art: ConversationBackdropView, ring: CAShapeLayer, caption: UILabel, button: UIButton)] = []
    private var headerHeight: CGFloat = 0
    var onScroll: (() -> Void)?
    var onSelect: ((ConversationBackground.Kind?) -> Void)?
    var current: ConversationBackground? { didSet { refreshSelection() } }

    static let circle: CGFloat = 86
    static let columns = 4

    override init() {
        super.init()
        scroll.alwaysBounceVertical = true
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.delegate = self
        scroll.accessibilityIdentifier = "conversation.details.backgrounds"
        for kind in ConversationBackgroundPickerViewController.categoryOrder {
            let art = ConversationBackdropView()
            art.isUserInteractionEnabled = false
            art.clipsToBounds = true
            art.backgroundColor = .tertiarySystemFill
            art.show(kind.flatMap(ConversationBackgroundPickerViewController.sample(for:)), animated: false)
            let ring = CAShapeLayer()
            ring.fillColor = nil
            ring.lineWidth = 3
            let caption = UILabel()
            caption.text = kind.map(ConversationBackgroundStrings.name) ?? ConversationBackgroundStrings.none
            caption.font = .systemFont(ofSize: 15)
            caption.textColor = .label
            caption.textAlignment = .center
            let button = UIButton(type: .custom)
            button.accessibilityLabel = caption.text
            button.accessibilityIdentifier = "conversation.details.background.\(kind?.rawValue ?? "none")"
            button.addAction(UIAction { [weak self] _ in self?.onSelect?(kind) }, for: .touchUpInside)
            caption.isAccessibilityElement = false
            scroll.addSubview(art)
            scroll.layer.addSublayer(ring)
            scroll.addSubview(caption)
            scroll.addSubview(button)
            tiles.append((kind, art, ring, caption, button))
        }
    }

    func setHeaderHeight(_ height: CGFloat, bottomInset: CGFloat) {
        headerHeight = height
        let width = scroll.bounds.width
        let pitch = (width - 40) / CGFloat(Self.columns)
        var maxY: CGFloat = height
        for (index, tile) in tiles.enumerated() {
            let column = CGFloat(index % Self.columns), row = CGFloat(index / Self.columns)
            let x = 20 + pitch * column + (pitch - Self.circle) / 2
            let y = height + row * (Self.circle + 46)
            tile.art.frame = CGRect(x: x, y: y, width: Self.circle, height: Self.circle)
            tile.art.layer.cornerRadius = Self.circle / 2
            tile.ring.path = UIBezierPath(ovalIn: tile.art.frame.insetBy(dx: -5, dy: -5)).cgPath
            tile.caption.frame = CGRect(x: x - 10, y: tile.art.frame.maxY + 8, width: Self.circle + 20, height: 18)
            tile.button.frame = CGRect(x: x, y: y, width: Self.circle, height: tile.caption.frame.maxY - y)
            maxY = tile.caption.frame.maxY
        }
        scroll.contentSize = CGSize(width: width, height: maxY + 20)
        scroll.contentInset.bottom = bottomInset
        refreshSelection()
    }

    private func refreshSelection() {
        for tile in tiles {
            let selected = tile.kind == current?.kind
            tile.ring.strokeColor = selected ? UIColor.tintColor.cgColor : UIColor.clear.cgColor
            tile.button.accessibilityTraits = selected ? [.button, .selected] : .button
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        onScroll?()
    }
}
#endif
