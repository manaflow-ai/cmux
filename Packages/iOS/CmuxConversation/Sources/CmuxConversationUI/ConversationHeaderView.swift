#if canImport(UIKit)
import CmuxConversationCore
import UIKit

/// Messages header: glass back capsule (with unread count), a centered
/// avatar (or group cluster) above a glass name pill, and a trailing glass
/// circle action that becomes an X in select and reply modes.
final class ConversationHeaderView: UIView {
    enum TrailingMode {
        case action
        case close
    }

    let backGlass = makeGlassView(cornerRadius: 22, interactive: true)
    let backButton = UIButton(type: .system)
    private let unreadLabel = UILabel()
    private let unreadPill = UIView()
    private var avatars: [ConversationAvatarView] = []
    /// Group chats seat their avatar cluster on a 60 pt glass disc.
    private let clusterDisc = makeGlassView(cornerRadius: 30)
    let namePillGlass = makeGlassView(cornerRadius: 16.5, interactive: true)
    let nameButton = UIButton(type: .system)
    private let nameLabel = UILabel()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)))
    let trailingGlass = makeGlassView(cornerRadius: 22, interactive: true)
    let trailingButton = UIButton(type: .system)
    private let avatarTapButton = UIButton(type: .custom)
    let statusLabel = UILabel()

    var onBack: (() -> Void)?
    var onInfo: (() -> Void)?
    var onTrailing: (() -> Void)?
    var trailingSymbol = "video"
    private(set) var trailingMode: TrailingMode = .action

    static let contentHeight: CGFloat = 92

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(backGlass)
        backGlass.contentView.addSubview(backButton)
        backButton.setImage(UIImage(systemName: "chevron.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold)), for: .normal)
        backButton.tintColor = .label
        backButton.accessibilityLabel = String(localized: "conversation.header.back", defaultValue: "Back", bundle: .module)
        backButton.addAction(UIAction { [weak self] _ in self?.onBack?() }, for: .touchUpInside)
        unreadPill.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.85, alpha: 1) : UIColor(white: 0.25, alpha: 1) }
        unreadLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        unreadLabel.textColor = UIColor { $0.userInterfaceStyle == .dark ? .black : .white }
        unreadLabel.textAlignment = .center
        backGlass.contentView.addSubview(unreadPill)
        unreadPill.addSubview(unreadLabel)
        unreadPill.isUserInteractionEnabled = false

        clusterDisc.isUserInteractionEnabled = false
        clusterDisc.isHidden = true
        addSubview(clusterDisc)
        addSubview(avatarTapButton)
        avatarTapButton.addAction(UIAction { [weak self] _ in self?.onInfo?() }, for: .touchUpInside)

        addSubview(namePillGlass)
        namePillGlass.contentView.addSubview(nameButton)
        nameLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        nameLabel.textColor = .label
        namePillGlass.contentView.addSubview(nameLabel)
        chevron.tintColor = .tertiaryLabel
        namePillGlass.contentView.addSubview(chevron)
        nameButton.addAction(UIAction { [weak self] _ in self?.onInfo?() }, for: .touchUpInside)
        nameButton.accessibilityIdentifier = "conversation.header.name"

        addSubview(trailingGlass)
        trailingGlass.contentView.addSubview(trailingButton)
        trailingButton.tintColor = .label
        trailingButton.addAction(UIAction { [weak self] _ in self?.onTrailing?() }, for: .touchUpInside)
        trailingButton.accessibilityIdentifier = "conversation.header.trailing"
        setTrailingMode(.action, animated: false)

        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.alpha = 0
        addSubview(statusLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(info: ConversationInfo, meID: String?, unreadCount: Int) {
        nameLabel.text = info.title
        nameButton.accessibilityLabel = info.title
        let others = info.participants.filter { $0.id != meID }
        let shown = info.kind == .group ? Array(others.prefix(3)) : Array(others.prefix(1))
        avatars.forEach { $0.removeFromSuperview() }
        avatars = shown.map { participant in
            let view = ConversationAvatarView()
            view.configure(initials: participant.initials, colorHex: nil)
            view.layer.borderWidth = info.kind == .group ? 1.5 : 0
            view.layer.borderColor = ConversationTheme.background.resolvedColor(with: traitCollection).cgColor
            insertSubview(view, belowSubview: namePillGlass)
            return view
        }
        clusterDisc.isHidden = info.kind != .group
        unreadLabel.text = unreadCount > 0 ? "\(unreadCount)" : nil
        unreadPill.isHidden = unreadCount <= 0
        setNeedsLayout()
    }

    func setConnectionStatus(_ text: String?) {
        statusLabel.text = text
        UIView.animate(withDuration: 0.25) { self.statusLabel.alpha = text == nil ? 0 : 1 }
    }

    func setTrailingMode(_ mode: TrailingMode, animated: Bool) {
        trailingMode = mode
        let symbol = mode == .close ? "xmark" : trailingSymbol
        let apply = {
            self.trailingButton.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: mode == .close ? 17 : 19, weight: mode == .close ? .semibold : .regular)), for: .normal)
            self.trailingButton.accessibilityLabel = mode == .close
                ? String(localized: "conversation.header.close", defaultValue: "Close", bundle: .module)
                : String(localized: "conversation.header.action", defaultValue: "Call", bundle: .module)
        }
        guard animated else { apply(); return }
        UIView.transition(with: trailingButton, duration: 0.2, options: .transitionCrossDissolve, animations: apply)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let top = safeAreaInsets.top
        let margin: CGFloat = 16
        let hasUnread = !unreadPill.isHidden
        unreadLabel.sizeToFit()
        let pillWidth = max(26, unreadLabel.bounds.width + 14)
        let backWidth: CGFloat = hasUnread ? 44 + pillWidth + 4 : 44
        backGlass.frame = CGRect(x: margin, y: top, width: backWidth, height: 44)
        backButton.frame = CGRect(x: 0, y: 0, width: 40, height: 44)
        unreadPill.frame = CGRect(x: 36, y: 11, width: pillWidth, height: 22)
        unreadPill.layer.cornerRadius = 11
        unreadLabel.frame = unreadPill.bounds

        trailingGlass.frame = CGRect(x: bounds.width - margin - 44, y: top, width: 44, height: 44)
        trailingButton.frame = trailingGlass.bounds

        let avatarSize: CGFloat = avatars.count > 1 ? 40 : 60
        let centerX = bounds.midX
        if avatars.count <= 1 {
            avatars.first?.frame = CGRect(x: centerX - avatarSize / 2, y: top, width: avatarSize, height: avatarSize)
        } else {
            // Cluster: the first large, the rest small and offset.
            clusterDisc.frame = CGRect(x: centerX - 30, y: top, width: 60, height: 60)
            avatars[0].frame = CGRect(x: centerX - 25, y: top + 6, width: 32, height: 32)
            if avatars.count > 1 { avatars[1].frame = CGRect(x: centerX + 2, y: top + 18, width: 24, height: 24) }
            if avatars.count > 2 { avatars[2].frame = CGRect(x: centerX - 14, y: top + 36, width: 18, height: 18) }
        }
        let clusterBottom = avatars.map(\.frame.maxY).max() ?? top + 60
        avatarTapButton.frame = CGRect(x: centerX - 40, y: top, width: 80, height: clusterBottom - top)

        nameLabel.sizeToFit()
        let pillWidth2 = min(bounds.width - 2 * (margin + 60), nameLabel.bounds.width + 36)
        let pillY = max(top + 53, clusterBottom - 7)
        namePillGlass.frame = CGRect(x: centerX - pillWidth2 / 2, y: pillY, width: pillWidth2, height: 33)
        nameLabel.frame = CGRect(x: 13, y: 0, width: pillWidth2 - 34, height: 33)
        chevron.frame = CGRect(x: pillWidth2 - 19, y: 11, width: 8, height: 11)
        nameButton.frame = namePillGlass.bounds
        statusLabel.frame = CGRect(x: 0, y: namePillGlass.frame.maxY + 2, width: bounds.width, height: 14)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Pass touches through the empty header area to the transcript.
        let view = super.hitTest(point, with: event)
        return view === self ? nil : view
    }
}
#endif
