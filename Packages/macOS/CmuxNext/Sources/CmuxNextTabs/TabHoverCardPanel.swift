import AppKit
import CmuxNextDesign
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
    private weak var parentWindowRef: NSWindow?
    private var thumbnailHeight: NSLayoutConstraint?
    private var thumbnailTop: NSLayoutConstraint?
    /// Group cards list at most this many member titles.
    static let maxGroupLines = 8

    init() {
        let content = NSView()
        glass = Glass.makePanel(content: content, cornerRadius: Metrics.panelCornerRadius)
        glass.translatesAutoresizingMaskIntoConstraints = true
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        ThemeStore.shared.adopt(self)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        animationBehavior = .none
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        contentView = glass

        titleLabel.font = Typography.bodyEmphasized
        titleLabel.textColor = Palette.textPrimary
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.preferredMaxLayoutWidth = Self.cardWidth - 2 * Self.padding
        subtitleLabel.font = Typography.caption
        subtitleLabel.textColor = Palette.textSecondary
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.maximumNumberOfLines = 1
        subtitleLabel.preferredMaxLayoutWidth = Self.cardWidth - 2 * Self.padding
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = Metrics.itemCornerRadius
        thumbnail.layer?.cornerCurve = .continuous
        thumbnail.layer?.masksToBounds = true
        thumbnail.layer?.contentsGravity = .resizeAspectFill
        thumbnail.layer?.actions = ["contents": Self.crossfade]

        for view in [titleLabel, subtitleLabel, thumbnail] {
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
            thumbnail.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: p),
            thumbnail.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -p),
            thumbnail.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -p),
        ])
        let top = thumbnail.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: Metrics.space4)
        let height = thumbnail.heightAnchor.constraint(equalToConstant: Self.thumbnailSize.height)
        NSLayoutConstraint.activate([top, height])
        thumbnailTop = top
        thumbnailHeight = height
    }

    private static let crossfade: CATransition = {
        let transition = CATransition()
        transition.type = .fade
        transition.duration = 0.15
        return transition
    }()

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func configure(_ content: TabHoverCardContent) {
        switch content {
        case .tab(let item):
            configure(title: item.title.isEmpty ? Strings.untitled : item.title, subtitle: item.subtitle, lines: 1)
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

    private func setThumbnailVisible(_ visible: Bool) {
        thumbnail.isHidden = !visible
        thumbnailHeight?.constant = visible ? Self.thumbnailSize.height : 0
        thumbnailTop?.constant = visible ? Metrics.space4 : 0
    }

    func setThumbnail(_ image: CGImage?) {
        guard let layer = thumbnail.layer else { return }
        glass.effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = Palette.hoverFill.cgColor
        }
        layer.contents = image
    }

    func present(below anchor: CGRect, parent: NSWindow, sliding: Bool) {
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
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if sliding, isVisible, !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().setFrame(frame, display: true)
            }
        } else {
            setFrame(frame, display: true)
        }
        if !isVisible || alphaValue < 1 {
            if !isVisible { alphaValue = 0 }
            orderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reduceMotion ? 0 : 0.12
                animator().alphaValue = 1
            }
        }
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.1
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.alphaValue == 0 else { return }
                self.parentWindowRef?.removeChildWindow(self)
                self.parentWindowRef = nil
                self.orderOut(nil)
            }
        }
    }
}
