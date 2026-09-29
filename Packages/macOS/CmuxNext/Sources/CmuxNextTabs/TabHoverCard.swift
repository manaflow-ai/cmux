import AppKit
import CmuxNextDesign
import QuartzCore

/// Shows a Liquid Glass preview card under a hovered tab, with Chrome timing:
/// a width-dependent delay before the first card, then instant updates while
/// the pointer moves across tabs.
final class TabHoverCardController {
    weak var previewProvider: (any TabPreviewProvider)?
    var policy = HoverCardPolicy()
    var metrics = TabStripMetrics.standard

    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: () -> ContinuousClock.Instant
    private var panel: TabHoverCardPanel?
    private var pendingShow: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    private(set) var shownID: TabID?
    private var pendingID: TabID?
    private var lastHidden: ContinuousClock.Instant?
    private var thumbnails: [TabID: CGImage] = [:]

    init(
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await ContinuousClock().sleep(for: $0) },
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.sleep = sleep
        self.now = now
    }

    var isVisible: Bool { shownID != nil }

    /// Pointer is over `tab`, whose frame on screen is `anchor`.
    func hover(_ tab: TabItem, anchor: CGRect, tabWidth: CGFloat, parent: NSWindow?) {
        if shownID == tab.id {
            return
        }
        if pendingID == tab.id { return }
        pendingShow?.cancel()
        let delay = policy.delay(
            tabWidth: tabWidth,
            cardIsVisible: isVisible,
            sinceLastHidden: lastHidden.map { now() - $0 },
            metrics: metrics
        )
        if delay == .zero {
            show(tab, anchor: anchor, parent: parent)
            return
        }
        pendingID = tab.id
        pendingShow = Task { [weak self, sleep] in
            do { try await sleep(delay) } catch { return }
            guard let self, !Task.isCancelled, self.pendingID == tab.id else { return }
            self.show(tab, anchor: anchor, parent: parent)
        }
    }

    /// Refreshes the visible card when its tab's title or subtitle changes.
    func refresh(_ tab: TabItem) {
        guard shownID == tab.id else { return }
        panel?.configure(title: tab.title.isEmpty ? Strings.untitled : tab.title, subtitle: tab.subtitle)
    }

    /// Hides the card. `allowsQuickReshow` starts Chrome's grace window in
    /// which the next hover shows a card without delay; clicks and scrolls
    /// pass false so a card does not pop up right after them.
    func hide(allowsQuickReshow: Bool = true) {
        pendingShow?.cancel()
        pendingShow = nil
        pendingID = nil
        thumbnailTask?.cancel()
        guard let panel, shownID != nil else { return }
        shownID = nil
        lastHidden = allowsQuickReshow ? now() : nil
        thumbnails.removeAll()
        panel.dismiss()
    }

    private func show(_ tab: TabItem, anchor: CGRect, parent: NSWindow?) {
        guard let parent, parent.isVisible else { return }
        pendingID = nil
        let wasVisible = isVisible
        let panel = panel ?? TabHoverCardPanel()
        self.panel = panel
        shownID = tab.id
        panel.configure(title: tab.title.isEmpty ? Strings.untitled : tab.title, subtitle: tab.subtitle)
        panel.setThumbnail(thumbnails[tab.id])
        panel.present(below: anchor, parent: parent, sliding: wasVisible)
        loadThumbnail(for: tab.id)
    }

    private func loadThumbnail(for id: TabID) {
        thumbnailTask?.cancel()
        guard let provider = previewProvider else { return }
        let scale = panel?.backingScaleFactor ?? 2
        let size = CGSize(width: TabHoverCardPanel.thumbnailSize.width * scale, height: TabHoverCardPanel.thumbnailSize.height * scale)
        thumbnailTask = Task { [weak self] in
            let image = await provider.previewImage(for: id, maxPixelSize: size)
            guard let self, !Task.isCancelled, self.shownID == id else { return }
            if let image { self.thumbnails[id] = image }
            self.panel?.setThumbnail(image)
        }
    }
}

/// Borderless, non-activating child window hosting the glass card.
final class TabHoverCardPanel: NSPanel {
    static let cardWidth: CGFloat = 260
    static let thumbnailSize = CGSize(width: 236, height: 148)
    private static let padding: CGFloat = 12

    private let glass: NSGlassEffectView
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let thumbnail = NSView()
    private weak var parentWindowRef: NSWindow?

    init() {
        let content = NSView()
        glass = Glass.makePanel(content: content, cornerRadius: 14)
        glass.translatesAutoresizingMaskIntoConstraints = true
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        animationBehavior = .none
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        contentView = glass

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = Palette.textPrimary
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.preferredMaxLayoutWidth = Self.cardWidth - 2 * Self.padding
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = Palette.textSecondary
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = 8
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
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            thumbnail.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 10),
            thumbnail.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: p),
            thumbnail.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -p),
            thumbnail.heightAnchor.constraint(equalToConstant: Self.thumbnailSize.height),
            thumbnail.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -p),
        ])
    }

    private static let crossfade: CATransition = {
        let transition = CATransition()
        transition.type = .fade
        transition.duration = 0.15
        return transition
    }()

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func configure(title: String, subtitle: String?) {
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle ?? ""
        subtitleLabel.isHidden = (subtitle ?? "").isEmpty
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
        var origin = CGPoint(x: anchor.minX, y: anchor.minY - 6 - size.height)
        if let screen = parent.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
            origin.y = max(origin.y, visible.minY + 4)
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
