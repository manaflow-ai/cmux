import AppKit
import CmuxFoundation
import Foundation
import Observation
import QuartzCore

/// Visual variants for the Pro upgrade badge shown in the sidebar footer and
/// the titlebar trailing controls.
enum ProBadgeStyle: String, CaseIterable, Identifiable {
    case textPro
    case textGetPro
    case textUpgrade
    case accentPro
    case gradientProSolid
    case crownPro
    case crownOnly
    case crownAccent
    case sparklesPro
    case boltPro
    case iphonePro
    case emojiCrownPro
    case emojiSparklesPro
    case emojiGemPro
    case emojiRocketPro

    var id: String { rawValue }

    enum Leading {
        case none
        case symbol(String)
        case emoji(String)
    }

    var leading: Leading {
        switch self {
        case .textPro, .textGetPro, .textUpgrade, .accentPro, .gradientProSolid: .none
        case .crownPro, .crownOnly, .crownAccent: .symbol("crown")
        case .sparklesPro: .symbol("sparkles")
        case .boltPro: .symbol("bolt.fill")
        case .iphonePro: .symbol("iphone")
        case .emojiCrownPro: .emoji("👑")
        case .emojiSparklesPro: .emoji("✨")
        case .emojiGemPro: .emoji("💎")
        case .emojiRocketPro: .emoji("🚀")
        }
    }

    var text: String? {
        switch self {
        case .crownOnly:
            nil
        case .textPro, .textUpgrade:
            String(localized: "sidebar.pro.badge", defaultValue: "Upgrade")
        case .textGetPro:
            String(localized: "pricing.native.upgrade", defaultValue: "Get Pro")
        default:
            String(localized: "pricing.native.plan.pro", defaultValue: "Pro")
        }
    }

    enum Appearance {
        case plain
        case gradientTint
        case gradientSolid
    }

    var appearance: Appearance {
        switch self {
        case .accentPro, .crownAccent: .gradientTint
        case .gradientProSolid: .gradientSolid
        default: .plain
        }
    }

    /// Debug-window label, intentionally developer-facing.
    var displayName: String {
        switch self {
        case .textPro: "Text: Pro"
        case .textGetPro: "Text: Get Pro"
        case .textUpgrade: "Text: Upgrade"
        case .accentPro: "Gradient: Pro (tint)"
        case .gradientProSolid: "Gradient: Pro (solid)"
        case .crownPro: "Crown + Pro"
        case .crownOnly: "Crown only"
        case .crownAccent: "Crown + Pro (gradient)"
        case .sparklesPro: "Sparkles + Pro"
        case .boltPro: "Bolt + Pro"
        case .iphonePro: "iPhone + Pro"
        case .emojiCrownPro: "👑 Pro"
        case .emojiSparklesPro: "✨ Pro"
        case .emojiGemPro: "💎 Pro"
        case .emojiRocketPro: "🚀 Pro"
        }
    }
}

extension Notification.Name {
    static let proBadgeStyleDidChange = Notification.Name("cmux.proBadgeStyleDidChange")
}

/// UserDefaults-backed selection shared by every badge surface and the debug window.
@MainActor
@Observable
final class ProBadgeStyleStore {
    static let shared = ProBadgeStyleStore()

    private static let defaultsKey = "debug.proBadgeStyle"
    private static let dismissedKey = "proBadge.dismissed"

    var current: ProBadgeStyle {
        didSet {
            guard current != oldValue else { return }
            UserDefaults.standard.set(current.rawValue, forKey: Self.defaultsKey)
            NotificationCenter.default.post(name: .proBadgeStyleDidChange, object: self)
        }
    }

    var isDismissed: Bool {
        didSet {
            guard isDismissed != oldValue else { return }
            UserDefaults.standard.set(isDismissed, forKey: Self.dismissedKey)
            NotificationCenter.default.post(name: .proBadgeStyleDidChange, object: self)
        }
    }

    private init() {
        current = UserDefaults.standard.string(forKey: Self.defaultsKey)
            .flatMap(ProBadgeStyle.init(rawValue:)) ?? .textPro
        isDismissed = UserDefaults.standard.bool(forKey: Self.dismissedKey)
    }
}

enum ProBadgePalette {
    static let gradientColors = [
        NSColor(red: 0x24 / 255, green: 0x9F / 255, blue: 0xFC / 255, alpha: 1).cgColor,
        NSColor(red: 0x4B / 255, green: 0x75 / 255, blue: 0xFF / 255, alpha: 1).cgColor,
    ]

    static func foreground(for style: ProBadgeStyle) -> NSColor {
        switch style.appearance {
        case .plain: .secondaryLabelColor
        case .gradientTint: NSColor(red: 0x36 / 255, green: 0x8A / 255, blue: 0xFE / 255, alpha: 1)
        case .gradientSolid: .white
        }
    }
}

/// Static native capsule rendering for one badge style.
@MainActor
final class ProBadgeLabelView: NSView {
    private let contentStack = NSStackView()
    private let gradientLayer = CAGradientLayer()
    private var style: ProBadgeStyle
    private var isHovered: Bool
    private let drawsCapsule: Bool

    override var isFlipped: Bool { true }

    init(style: ProBadgeStyle, isHovered: Bool = false, drawsCapsule: Bool = true) {
        self.style = style
        self.isHovered = isHovered
        self.drawsCapsule = drawsCapsule
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        gradientLayer.colors = ProBadgePalette.gradientColors
        gradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.insertSublayer(gradientLayer, at: 0)
        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = 3
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: drawsCapsule ? 7 : 0),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: drawsCapsule ? -7 : 0),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        rebuildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        let content = contentStack.fittingSize
        return NSSize(width: ceil(content.width) + (drawsCapsule ? 14 : 0), height: 16)
    }

    override func layout() {
        super.layout()
        gradientLayer.frame = bounds
    }

    func update(style: ProBadgeStyle, isHovered: Bool = false) {
        let contentChanged = self.style != style
        self.style = style
        self.isHovered = isHovered
        if contentChanged { rebuildContent() }
        updateChrome()
    }

    private func rebuildContent() {
        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let foreground = ProBadgePalette.foreground(for: style)
        switch style.leading {
        case .none:
            break
        case .symbol(let name):
            let image = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage())
            image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
            image.contentTintColor = foreground
            contentStack.addArrangedSubview(image)
        case .emoji(let emoji):
            let label = NSTextField(labelWithString: emoji)
            label.font = .systemFont(ofSize: 9)
            contentStack.addArrangedSubview(label)
        }
        if let text = style.text {
            let label = NSTextField(labelWithString: text)
            label.font = GlobalFontMagnification.systemFont(ofSize: 10, weight: .semibold)
            label.textColor = foreground
            contentStack.addArrangedSubview(label)
        }
        setAccessibilityLabel(style.text ?? style.displayName)
        invalidateIntrinsicContentSize()
        updateChrome()
    }

    private func updateChrome() {
        guard drawsCapsule else {
            layer?.borderWidth = 0
            layer?.backgroundColor = NSColor.clear.cgColor
            gradientLayer.opacity = 0
            return
        }
        switch style.appearance {
        case .plain:
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.borderWidth = 1
            layer?.backgroundColor = isHovered ? NSColor.quaternaryLabelColor.cgColor : NSColor.clear.cgColor
            gradientLayer.opacity = 0
        case .gradientTint:
            layer?.borderWidth = 0
            layer?.backgroundColor = NSColor.clear.cgColor
            gradientLayer.opacity = isHovered ? 0.32 : 0.18
        case .gradientSolid:
            layer?.borderWidth = 0
            layer?.backgroundColor = NSColor.clear.cgColor
            gradientLayer.opacity = isHovered ? 0.85 : 1
        }
    }
}

/// Native interactive Pro badge used by all app surfaces.
@MainActor
final class ProBadgeView: NSView {
    private let backgroundView = NSView(frame: .zero)
    private let gradientLayer = CAGradientLayer()
    private let labelView = ProBadgeLabelView(style: ProBadgeStyleStore.shared.current, drawsCapsule: false)
    private let upgradeButton = NSButton(frame: .zero)
    private let dismissButton = NSButton(frame: .zero)
    private var trackingAreaReference: NSTrackingArea?
    private var styleObserver: NSObjectProtocol?
    private var hovered = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 8
        backgroundView.layer?.masksToBounds = true
        gradientLayer.colors = ProBadgePalette.gradientColors
        gradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
        backgroundView.layer?.insertSublayer(gradientLayer, at: 0)
        addSubview(backgroundView)
        backgroundView.addSubview(labelView)

        let helpTitle = String(localized: "menu.help.upgradeToPro", defaultValue: "Upgrade to cmux Pro…")
        upgradeButton.title = ""
        upgradeButton.isBordered = false
        upgradeButton.bezelStyle = .inline
        upgradeButton.target = self
        upgradeButton.action = #selector(openUpgrade)
        upgradeButton.toolTip = helpTitle
        upgradeButton.setAccessibilityLabel(helpTitle)
        upgradeButton.setAccessibilityIdentifier("ProBadgeButton")
        backgroundView.addSubview(upgradeButton)

        let dismissTitle = String(localized: "sidebar.pro.badge.dismiss", defaultValue: "Hide the Pro badge")
        dismissButton.title = ""
        dismissButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: dismissTitle)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .bold))
        dismissButton.isBordered = false
        dismissButton.bezelStyle = .inline
        dismissButton.target = self
        dismissButton.action = #selector(dismissBadge)
        dismissButton.toolTip = dismissTitle
        dismissButton.setAccessibilityLabel(dismissTitle)
        dismissButton.setAccessibilityIdentifier("ProBadgeDismissButton")
        backgroundView.addSubview(dismissButton)

        styleObserver = NotificationCenter.default.addObserver(
            forName: .proBadgeStyleDidChange,
            object: ProBadgeStyleStore.shared,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPresentation() }
        }
        refreshPresentation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let styleObserver { NotificationCenter.default.removeObserver(styleObserver) }
    }

    override var intrinsicContentSize: NSSize {
        guard !isHidden else { return .zero }
        return NSSize(width: labelView.intrinsicContentSize.width + 14 + (hovered ? 18 : 0), height: 22)
    }

    override func layout() {
        super.layout()
        let capsuleFrame = NSRect(x: 0, y: 3, width: bounds.width, height: 16)
        backgroundView.frame = capsuleFrame
        gradientLayer.frame = backgroundView.bounds
        let dismissWidth: CGFloat = hovered ? 18 : 0
        labelView.frame = NSRect(x: 7, y: 0, width: labelView.intrinsicContentSize.width, height: 16)
        upgradeButton.frame = NSRect(x: 0, y: 0, width: max(0, bounds.width - dismissWidth), height: 16)
        dismissButton.frame = NSRect(x: max(0, bounds.width - dismissWidth), y: 0, width: dismissWidth, height: 16)
    }

    override func updateTrackingAreas() {
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        )
        addTrackingArea(area)
        trackingAreaReference = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        ProUpgradePresenter.prefetch()
        refreshPresentation(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        refreshPresentation(animated: true)
    }

    private func refreshPresentation(animated: Bool = false) {
        let store = ProBadgeStyleStore.shared
        isHidden = !CmuxFeatureFlags.shared.isProUpgradeUIEnabled || store.isDismissed
        let style = store.current
        labelView.update(style: style)
        dismissButton.contentTintColor = ProBadgePalette.foreground(for: style).withAlphaComponent(0.75)
        switch style.appearance {
        case .plain:
            backgroundView.layer?.borderColor = NSColor.separatorColor.cgColor
            backgroundView.layer?.borderWidth = 1
            backgroundView.layer?.backgroundColor = hovered ? NSColor.quaternaryLabelColor.cgColor : NSColor.clear.cgColor
            gradientLayer.opacity = 0
        case .gradientTint:
            backgroundView.layer?.borderWidth = 0
            backgroundView.layer?.backgroundColor = NSColor.clear.cgColor
            gradientLayer.opacity = hovered ? 0.32 : 0.18
        case .gradientSolid:
            backgroundView.layer?.borderWidth = 0
            backgroundView.layer?.backgroundColor = NSColor.clear.cgColor
            gradientLayer.opacity = hovered ? 0.85 : 1
        }
        dismissButton.isHidden = !hovered
        invalidateIntrinsicContentSize()
        needsLayout = true
        guard animated else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layoutSubtreeIfNeeded()
        }
    }

    @objc private func openUpgrade() { ProUpgradePresenter.present() }
    @objc private func dismissBadge() { ProBadgeStyleStore.shared.isDismissed = true }
}

/// Debug window listing every badge variant with a live native preview.
@MainActor
final class ProBadgeDebugWindowController: ReleasingWindowController {
    static let shared = ProBadgeDebugWindowController()

    override func makeWindow() -> NSWindow {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 520),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Pro Badge Style"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.identifier = NSUserInterfaceItemIdentifier("cmux.proBadgeDebug")
        window.center()
        window.contentView = ProBadgeDebugView(frame: window.contentRect(forFrameRect: window.frame))
        AppDelegate.shared?.applyWindowDecorations(to: window)
        return window
    }

    func show() { showManagedWindow() }
}

@MainActor
private final class ProBadgeDebugView: NSView {
    private let documentView = ProBadgeDebugFlippedView(frame: .zero)
    private let stack = NSStackView()
    private var styleObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let scrollView = NSScrollView(frame: bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        addSubview(scrollView)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -12),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])
        styleObserver = NotificationCenter.default.addObserver(
            forName: .proBadgeStyleDidChange,
            object: ProBadgeStyleStore.shared,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildRows() }
        }
        rebuildRows()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let styleObserver { NotificationCenter.default.removeObserver(styleObserver) }
    }

    private func rebuildRows() {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let explanation = NSTextField(labelWithString: "Applies live to the sidebar footer and titlebar badge.")
        explanation.font = GlobalFontMagnification.systemFont(ofSize: 11)
        explanation.textColor = .secondaryLabelColor
        stack.addArrangedSubview(explanation)
        stack.setCustomSpacing(8, after: explanation)

        if ProBadgeStyleStore.shared.isDismissed {
            let restore = NSButton(title: "Badge is dismissed, show it again", target: self, action: #selector(restoreBadge))
            stack.addArrangedSubview(restore)
            stack.setCustomSpacing(8, after: restore)
        }
        for (index, style) in ProBadgeStyle.allCases.enumerated() {
            let row = ProBadgeDebugRowView(
                style: style,
                isSelected: style == ProBadgeStyleStore.shared.current,
                target: self,
                action: #selector(selectStyle(_:))
            )
            row.tag = index
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    @objc private func restoreBadge() { ProBadgeStyleStore.shared.isDismissed = false }

    @objc private func selectStyle(_ sender: NSControl) {
        guard ProBadgeStyle.allCases.indices.contains(sender.tag) else { return }
        ProBadgeStyleStore.shared.current = ProBadgeStyle.allCases[sender.tag]
    }
}

@MainActor
private final class ProBadgeDebugRowView: NSControl {
    init(style: ProBadgeStyle, isSelected: Bool, target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = isSelected ? NSColor.quaternaryLabelColor.cgColor : NSColor.clear.cgColor
        let selection = NSImageView(image: NSImage(
            systemSymbolName: isSelected ? "largecircle.fill.circle" : "circle",
            accessibilityDescription: nil
        ) ?? NSImage())
        selection.contentTintColor = isSelected ? .controlAccentColor : .secondaryLabelColor
        let badge = ProBadgeLabelView(style: style)
        let label = NSTextField(labelWithString: style.displayName)
        label.font = GlobalFontMagnification.systemFont(ofSize: 12)
        let spacer = NSView()
        let row = NSStackView(views: [selection, badge, label, spacer])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
        ])
        self.target = target
        self.action = action
        sendAction(on: .leftMouseUp)
        setAccessibilityLabel(style.displayName)
        setAccessibilityRole(.radioButton)
        setAccessibilitySelected(isSelected)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
private final class ProBadgeDebugFlippedView: NSView {
    override var isFlipped: Bool { true }
}
