public import AppKit
import CmuxNextDesign

/// The Chief's profile page (Lawrence's reference, 2026-11-04), a tab in Home's right column: a close
/// button, the avatar and name centered, then Details and Computer. The Chief's settings stay in the
/// header's popover; Details links to them. Computer always shows, so the feature can be found:
/// without a plan that pays for cmux Cloud it is the upsell, for a Chief that does not run in the
/// Cloud it offers the move, and until the Chief sets one up it says how to ask.
@MainActor
public final class HomeChiefProfileView: NSView {
    /// Why the Computer tab has no screen; nil when it does.
    public enum Gate: Equatable, Sendable {
        case paywall, needsCloudChief, notSetUp
    }

    /// The gate for a read: the plan first, since the upsell is the same wherever the Chief runs.
    public nonisolated static func gate(paid: Bool, cloudChief: Bool, hasComputer: Bool) -> Gate? {
        guard paid else { return .paywall }
        guard cloudChief else { return .needsCloudChief }
        return hasComputer ? nil : .notSetUp
    }

    static let columnWidth: CGFloat = 288
    static let avatarSize: CGFloat = 60
    static let avatarTop: CGFloat = 74
    static let nameGap: CGFloat = 12
    static let tabsGap: CGFloat = 20

    public let computer = HomeChiefComputerSection()
    /// The Chief's name, read when the page opens and at each status read.
    public var name: () -> String = { "" } { didSet { refresh() } }
    /// Whether the plan pays for cmux Cloud.
    public var paid: () -> Bool = { false } { didSet { refresh() } }
    /// Whether the Chief runs in the Cloud.
    public var cloudChief: () -> Bool = { false } { didSet { refresh() } }
    /// Where the Chief runs, for Details.
    public var place: () -> String = { "" } { didSet { refresh() } }
    /// The ✕ (the app closes the tab).
    public var onClose: () -> Void = {}
    /// Upgrade, on the paywall.
    public var onUpgrade: () -> Void = {}
    /// Move to Cloud, for a Chief of this Mac.
    public var onMoveToCloud: () -> Void = {}
    /// All Chief Settings…, in Details.
    public var onSettings: () -> Void = {}

    let tabs = HomeChiefSettingsTabs()
    let avatar = HomeChiefAvatarButton(size: avatarSize)
    let nameLabel = ThemedLabel(labelWithString: "")
    let details = NSStackView()
    let placeLabel = ThemedLabel(labelWithString: "")
    let computerPane = NSStackView()
    /// The note and button that stand in for the screen.
    let gateBox = NSView()
    let gateLabel = ThemedLabel(wrappingLabelWithString: "")
    let gateButton = NSButton(title: "", target: nil, action: nil)
    private(set) lazy var closeButton = HomeChiefCardCloseButton(label: HomeEngineStrings.closeCard, target: self, action: #selector(closeTab))
    /// What the tab shows now.
    private(set) var shownGate: Gate?

    public override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("cmux.home.chief.profile")
        avatar.isEnabled = false
        nameLabel.font = Typography.system(size: TypeScale.title, weight: TypeScale.regular)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        placeLabel.font = Typography.body
        placeLabel.ink = .secondary
        placeLabel.alignment = .center
        let settings = HomeChiefLinkButton(title: HomeEngineStrings.allChiefSettings, target: self, action: #selector(openSettings))
        details.orientation = .vertical
        details.alignment = .centerX
        details.spacing = Metrics.space2
        details.addArrangedSubview(placeLabel)
        details.addArrangedSubview(settings)
        buildGateBox()
        computerPane.orientation = .vertical
        computerPane.alignment = .centerX
        computerPane.addArrangedSubview(computer)
        computerPane.addArrangedSubview(gateBox)
        let column = NSStackView(views: [avatar, nameLabel, tabs, details, computerPane])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 0
        column.setCustomSpacing(Self.nameGap, after: avatar)
        column.setCustomSpacing(Self.tabsGap, after: nameLabel)
        column.setCustomSpacing(Self.tabsGap, after: tabs)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        addSubview(closeButton)
        for view in [nameLabel, details, computerPane] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        computer.translatesAutoresizingMaskIntoConstraints = false
        gateBox.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: Self.avatarTop),
            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: Self.columnWidth),
            column.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
            column.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            computer.widthAnchor.constraint(equalTo: computerPane.widthAnchor),
            gateBox.widthAnchor.constraint(equalTo: computerPane.widthAnchor),
            gateBox.heightAnchor.constraint(equalTo: gateBox.widthAnchor, multiplier: 10.0 / 16.0),
        ])
        let wide = column.widthAnchor.constraint(equalToConstant: Self.columnWidth)
        wide.priority = .defaultHigh
        wide.isActive = true
        tabs.select(.computer)
        tabs.onPick = { [weak self] _ in self?.refresh() }
        computer.onResize = { [weak self] in self?.refresh() }
        computer.onStatus = { [weak self] in self?.refresh() }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    nonisolated public override var isFlipped: Bool { true }

    /// The avatar the Home header shows.
    public func setAvatar(picture: NSImage?, text: String?) {
        avatar.show(picture: picture, text: text)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { computer.open() }
        applyGateFill()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyGateFill()
    }

    /// Shows the selected tab and, on Computer, the screen or why there is none.
    func refresh() {
        nameLabel.stringValue = name()
        placeLabel.stringValue = place()
        let onComputer = tabs.selected == .computer
        details.isHidden = onComputer
        computerPane.isHidden = !onComputer
        computer.watchesScreen = onComputer
        let gate = Self.gate(paid: paid(), cloudChief: cloudChief(), hasComputer: computer.shown != nil)
        shownGate = gate
        gateBox.isHidden = gate == nil
        switch gate {
        case .paywall:
            gateLabel.stringValue = HomeEngineStrings.computerPaywall(name())
            gateButton.title = HomeEngineStrings.computerUpgrade
            gateButton.isHidden = false
        case .needsCloudChief:
            gateLabel.stringValue = HomeEngineStrings.computerNeedsCloudChief(name())
            gateButton.title = HomeEngineStrings.computerMove
            gateButton.isHidden = false
        case .notSetUp:
            gateLabel.stringValue = HomeEngineStrings.computerNotSetUp(name())
            gateButton.isHidden = true
        case nil:
            break
        }
    }

    private func buildGateBox() {
        gateBox.wantsLayer = true
        gateBox.layer?.cornerRadius = HomeChiefComputerSection.screenCorner
        gateBox.layer?.cornerCurve = .continuous
        gateLabel.font = Typography.system(size: TypeScale.field, weight: TypeScale.regular)
        gateLabel.alignment = .center
        gateButton.bezelStyle = .rounded
        gateButton.target = self
        gateButton.action = #selector(gateAction)
        gateButton.setAccessibilityIdentifier("cmux.home.chief.computer.gate")
        let note = NSStackView(views: [gateLabel, gateButton])
        note.orientation = .vertical
        note.alignment = .centerX
        note.spacing = Metrics.space3
        note.translatesAutoresizingMaskIntoConstraints = false
        gateBox.addSubview(note)
        NSLayoutConstraint.activate([
            note.centerXAnchor.constraint(equalTo: gateBox.centerXAnchor),
            note.centerYAnchor.constraint(equalTo: gateBox.centerYAnchor),
            note.widthAnchor.constraint(equalTo: gateBox.widthAnchor, constant: -32),
        ])
        gateLabel.preferredMaxLayoutWidth = Self.columnWidth - 32
    }

    private func applyGateFill() {
        performWithTheme { gateBox.layer?.backgroundColor = Palette.hoverFill.cgColor }
    }

    @objc private func gateAction() {
        if shownGate == .paywall { onUpgrade() } else { onMoveToCloud() }
    }

    @objc private func closeTab() { onClose() }
    @objc private func openSettings() { onSettings() }
}
