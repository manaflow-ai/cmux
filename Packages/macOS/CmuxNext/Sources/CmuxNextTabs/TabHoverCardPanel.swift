import AppKit
import CmuxNextDesign
import CmuxNextResources
import QuartzCore

/// Borderless, non-activating child window hosting the glass card.
final class TabHoverCardPanel: NSPanel {
    private static var padding: CGFloat { Metrics.space5 }
    static var thumbnailSize: CGSize {
        // 16:10, as wide as a full tab.
        CGSize(width: Metrics.tabMaxWidth, height: (Metrics.tabMaxWidth * 10 / 16).rounded())
    }

    static var cardWidth: CGFloat { thumbnailSize.width + 2 * padding }

    private let glass: NSGlassEffectView
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let thumbnail = NSView()
    /// CPU and memory of the hovered tab (tab cards only).
    let resources = ResourceSummaryView()
    private var resourcesCollapsed: NSLayoutConstraint?
    private weak var parentWindowRef: NSWindow?
    private var thumbnailHeight: NSLayoutConstraint?
    private var thumbnailTop: NSLayoutConstraint?
    /// Group cards list at most this many member titles.
    static let maxGroupLines = 8

    init() {
        let content = ThemeHookView()
        glass = Glass.makePanel(content: content, cornerRadius: Metrics.panelCornerRadius)
        glass.translatesAutoresizingMaskIntoConstraints = true
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        // A no-activate test run is never active; its cards must still show.
        hidesOnDeactivate = !WindowPlacement.noActivate
        animationBehavior = .none
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        contentView = glass
        content.onThemeChange = { [weak self] in self?.applyColors() }

        titleLabel.font = Typography.bodyEmphasized
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.preferredMaxLayoutWidth = Self.cardWidth - 2 * Self.padding
        subtitleLabel.font = Typography.caption
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.maximumNumberOfLines = 1
        subtitleLabel.preferredMaxLayoutWidth = Self.cardWidth - 2 * Self.padding
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = Metrics.itemCornerRadius
        thumbnail.layer?.cornerCurve = .continuous
        thumbnail.layer?.masksToBounds = true
        thumbnail.layer?.contentsGravity = .resizeAspectFill
        thumbnail.layer?.actions = ["contents": Motion.crossfadeAction]

        for view in [titleLabel, subtitleLabel, resources, thumbnail] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        let p = Self.padding
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: Self.cardWidth),
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: p),
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: p),
            titleLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -p),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: Metrics.space1),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            resources.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: Metrics.space1),
            resources.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            resources.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            thumbnail.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: p),
            thumbnail.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -p),
            thumbnail.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -p),
        ])
        let top = thumbnail.topAnchor.constraint(equalTo: resources.bottomAnchor, constant: Metrics.space4)
        resourcesCollapsed = resources.heightAnchor.constraint(equalToConstant: 0)
        let height = thumbnail.heightAnchor.constraint(equalToConstant: Self.thumbnailSize.height)
        NSLayoutConstraint.activate([top, height])
        thumbnailTop = top
        thumbnailHeight = height
    }

    /// Label colors in the scope of the strip the card belongs to; runs on
    /// adopt and on every theme change of that scope.
    private func applyColors() {
        glass.performWithTheme {
            glass.tintColor = Palette.glassTint
            titleLabel.textColor = Palette.textPrimary
            subtitleLabel.textColor = Palette.textSecondary
            thumbnail.layer?.backgroundColor = Palette.hoverFill.cgColor
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func configure(_ content: TabHoverCardContent) {
        switch content {
        case .tab(let item):
            let subtitle = [item.machineBadgeHelp, item.subtitle].compactMap(\.self).joined(separator: " · ")
            configure(title: item.title.isEmpty ? Strings.untitled : item.title, subtitle: subtitle.isEmpty ? nil : subtitle, lines: 1)
            setResourcesVisible(true)
            setThumbnailVisible(true)
        case .group(let group, let titles):
            let shown = titles.prefix(Self.maxGroupLines)
            var lines = Array(shown)
            if titles.count > shown.count { lines.append(Strings.groupMore(titles.count - shown.count)) }
            configure(
                title: group.name.isEmpty ? Strings.groupTabCount(titles.count) : group.name,
                subtitle: lines.joined(separator: "\n"),
                lines: lines.count
            )
            setResourcesVisible(false)
            setThumbnailVisible(false)
        }
    }

    private func configure(title: String, subtitle: String?, lines: Int) {
        titleLabel.stringValue = title
        subtitleLabel.maximumNumberOfLines = lines
        subtitleLabel.lineBreakMode = lines > 1 ? .byTruncatingTail : .byTruncatingMiddle
        subtitleLabel.stringValue = subtitle ?? ""
        subtitleLabel.isHidden = (subtitle ?? "").isEmpty
    }

    private func setResourcesVisible(_ visible: Bool) {
        resources.isHidden = !visible
        resourcesCollapsed?.isActive = !visible
        if !visible { resources.show(nil) }
    }

    /// Shows the latest sample; nil shows the placeholder line.
    func setResources(_ report: ResourceReport?) {
        resources.show(report)
    }

    private func setThumbnailVisible(_ visible: Bool) {
        thumbnail.isHidden = !visible
        thumbnailHeight?.constant = visible ? Self.thumbnailSize.height : 0
        thumbnailTop?.constant = visible ? Metrics.space4 : 0
    }

    func setThumbnail(_ image: CGImage?) {
        guard let layer = thumbnail.layer else { return }
        glass.performWithTheme {
            layer.backgroundColor = Palette.hoverFill.cgColor
        }
        Motion.transaction(.crossfade) { layer.contents = image }
    }

    /// `themeAnchor` is the view the card describes (the tab strip); the
    /// card draws in its theme scope (room or workspace theme).
    func present(below anchor: CGRect, parent: NSWindow, themeAnchor: NSView?, sliding: Bool) {
        if let themeAnchor { adoptThemeScope(of: themeAnchor) } else { parent.themeScope.adopt(self) }
        applyColors()
        if parentWindowRef !== parent {
            parentWindowRef?.removeChildWindow(self)
            parent.addChildWindow(self, ordered: .above)
            parentWindowRef = parent
        }
        glass.layoutSubtreeIfNeeded()
        let size = glass.fittingSize
        var origin = CGPoint(x: anchor.minX, y: anchor.minY - Metrics.space2 - size.height)
        if let screen = parent.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            let margin = Metrics.space2
            origin.x = min(max(origin.x, visible.minX + margin), visible.maxX - size.width - margin)
            origin.y = max(origin.y, visible.minY + margin)
        }
        let frame = CGRect(origin: origin, size: size)
        if sliding, isVisible, Motion.animatesMovement {
            Motion.animateTimed(.panel) { animator().setFrame(frame, display: true) }
        } else {
            setFrame(frame, display: true)
        }
        if !isVisible || alphaValue < 1 {
            if !isVisible { alphaValue = 0 }
            orderFront(nil)
            Motion.animateTimed(.fadeIn) { animator().alphaValue = 1 }
        }
    }

    func dismiss() {
        Motion.animateTimed(.fadeOut, { animator().alphaValue = 0 }, completion: { [weak self] in
            guard let self, self.alphaValue == 0 else { return }
            self.parentWindowRef?.removeChildWindow(self)
            self.parentWindowRef = nil
            self.orderOut(nil)
        })
    }
}
