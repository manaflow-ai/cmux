import AppKit
import CmuxNextDesign

/// Chrome variant A (decision D-RD4): a floating Liquid Glass pill at the top
/// center of the pane. Host name, path badge with RTT, View/Control toggle,
/// display picker, quality menu and Stop. The pane shows it on hover, and
/// pins it while no live picture is shown.
final class RemoteHoverToolbar: NSView {
    var onSelectMode: ((RemoteControlMode) -> Void)?
    var onSelectQuality: ((RemoteQualityPreset) -> Void)?
    var onSelectDisplay: ((Int) -> Void)?
    var onStop: (() -> Void)?
    /// A per-kind share button: start sharing, or stop an active kind.
    var onUpstream: ((RemoteUpstreamKind) -> Void)?

    static let height: CGFloat = 38
    let surface = Glass.makeOverlayPanel(cornerRadius: RemoteHoverToolbar.height / 2)
    private let icon = RemoteChrome.symbol("display", size: 12)
    private let hostLabel = RemoteChrome.label("", size: 12.5, weight: .semibold)
    private let badge = RemotePathBadgeView()
    private let toggle = RemoteModeToggle()
    private let displayButton = RemoteChromeButton(title: RemoteViewStrings.display(1), symbol: "chevron.down")
    private let qualityButton = RemoteChromeButton(title: RemoteViewStrings.quality(.auto), symbol: "dial.medium")
    private let stopButton = RemoteChromeButton(title: RemoteViewStrings.stop, symbol: "stop.fill")
    private let dividers = [RemoteChrome.divider(), RemoteChrome.divider(), RemoteChrome.divider()]
    private let upstreamButtons: [RemoteUpstreamKind: RemoteChromeButton] = Dictionary(
        uniqueKeysWithValues: RemoteUpstreamKind.allCases.map { ($0, RemoteChromeButton(title: "", symbol: RemoteUpstreamIndicator.symbol($0))) }
    )
    private var sessionViews: [NSView] { [dividers[0], toggle, dividers[1], displayButton, qualityButton, stopButton] }
    private var upstreamViews: [NSView] {
        [dividers[2]] + RemoteUpstreamKind.allCases.compactMap { upstreamButtons[$0] }
    }
    private var quality = RemoteQualityPreset.auto

    override init(frame: NSRect) {
        super.init(frame: frame)
        let row = RemoteChrome.row(
            [icon, hostLabel, badge, dividers[0], toggle, dividers[1], displayButton, qualityButton]
                + upstreamViews + [stopButton],
            spacing: 8, insets: NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 6))
        row.setCustomSpacing(6, after: icon)
        surface.contentView.addSubview(row)
        surface.translatesAutoresizingMaskIntoConstraints = true
        surface.autoresizingMask = [.width, .height]
        addSubview(surface)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: surface.contentView.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: surface.contentView.trailingAnchor),
            row.centerYAnchor.constraint(equalTo: surface.contentView.centerYAnchor),
        ])
        displayButton.imagePosition = .imageTrailing
        toggle.onSelect = { [weak self] in self?.onSelectMode?($0) }
        stopButton.onPress = { [weak self] in self?.onStop?() }
        displayButton.onPress = { [weak self] in self?.showDisplayMenu() }
        qualityButton.onPress = { [weak self] in self?.showQualityMenu() }
        for (kind, button) in upstreamButtons {
            button.onPress = { [weak self] in self?.onUpstream?(kind) }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The width the content wants (the pane centers the pill at this width).
    var fittingWidth: CGFloat {
        surface.contentView.subviews.first?.fittingSize.width ?? 0
    }

    override func layout() {
        super.layout()
        surface.frame = bounds
    }

    func update(state: RemotePaneState, settings: RemoteDesktopSettings, colors: RemotePaneColors) {
        quality = settings.quality
        hostLabel.stringValue = state.hostName
        hostLabel.textColor = colors.textPrimary
        icon.contentTintColor = colors.textSecondary
        badge.isHidden = !settings.showPathBadge
        badge.update(status: state.status, ended: state.isEnded, colors: colors)
        for view in sessionViews { view.isHidden = !state.showsSessionControls }
        toggle.update(selected: state.effectiveMode, colors: colors)
        for divider in dividers { divider.layer?.backgroundColor = colors.separator.cgColor }
        qualityButton.title = RemoteViewStrings.quality(settings.quality)
        for button in [displayButton, qualityButton] {
            button.apply(text: colors.textSecondary, hover: colors.hoverFill)
        }
        stopButton.apply(text: colors.danger, hover: colors.hoverFill)
        for view in upstreamViews { view.isHidden = !state.showsUpstreamButtons }
        let upstream = state.upstream
        for (kind, button) in upstreamButtons {
            let on = upstream.active.contains(kind) || upstream.requested.contains(kind)
            button.apply(text: on ? colors.accent : colors.textSecondary, hover: colors.hoverFill, fill: on ? colors.selectionFill : .clear)
            let label = on ? RemoteViewStrings.stopSharing(kind) : RemoteViewStrings.share(kind)
            button.setAccessibilityLabel(label)
            button.toolTip = label
        }
        setAccessibilityLabel(RemoteViewStrings.accessibilityPane(state.hostName))
    }

    /// Placeholder until the host reports its display list (multi-monitor is phase 2).
    private func showDisplayMenu() {
        let menu = NSMenu()
        let current = NSMenuItem(title: RemoteViewStrings.display(1), action: nil, keyEquivalent: "")
        current.state = .on
        menu.addItem(current)
        menu.addItem(.separator())
        let placeholder = NSMenuItem(title: RemoteViewStrings.displayPlaceholder, action: nil, keyEquivalent: "")
        placeholder.isEnabled = false
        menu.addItem(placeholder)
        menu.popUp(positioning: nil, at: CmuxPopoverAnchor.menuPoint(in: displayButton, gap: 4), in: displayButton)
    }

    private func showQualityMenu() {
        let menu = NSMenu()
        for preset in RemoteQualityPreset.allCases {
            let target = RemoteMenuTarget { [weak self] in self?.onSelectQuality?(preset) }
            let item = NSMenuItem(title: RemoteViewStrings.quality(preset), action: #selector(RemoteMenuTarget.run), keyEquivalent: "")
            item.target = target
            // The menu item keeps its target alive while the menu exists.
            item.representedObject = target
            item.state = preset == quality ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: CmuxPopoverAnchor.menuPoint(in: qualityButton, gap: 4), in: qualityButton)
    }
}

/// The target of a menu item that runs a closure.
final class RemoteMenuTarget: NSObject {
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
        super.init()
    }

    @objc func run() { handler() }
}
