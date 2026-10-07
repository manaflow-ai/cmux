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
    private let info: ConversationInfo
    private let meID: String?
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

    init(info: ConversationInfo, meID: String?) {
        self.info = info
        self.meID = meID
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

    // MARK: Table

    func numberOfSections(in tableView: UITableView) -> Int { 1 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        info.participants.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        info.kind == .group
            ? String(format: String(localized: "conversation.info.members", defaultValue: "%d Members", bundle: .module), info.participants.count)
            : nil
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "p", for: indexPath)
        let participant = info.participants[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = participant.isMe ? String(localized: "conversation.reaction.you", defaultValue: "You", bundle: .module) : participant.name
        cell.contentConfiguration = content
        // Messages' cards are translucent over the panel's material.
        var background = UIBackgroundConfiguration.listGroupedCell()
        background.backgroundColor = .tertiarySystemFill
        cell.backgroundConfiguration = background
        cell.selectionStyle = .none
        return cell
    }
}
#endif
