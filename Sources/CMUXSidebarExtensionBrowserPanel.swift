@_spi(CmuxHostTransport) import CmuxSidebar
import AppKit
import CmuxFoundation
import SwiftUI

@MainActor
final class CMUXSidebarExtensionBrowserPanel: NSObject, Panel, ObservableObject {
    let id = UUID()
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .extensionBrowser
    let browserViewController: NSViewController

    private let title: String

    var displayTitle: String { title }
    var displayIcon: String? { "puzzlepiece.extension" }

    init(title: String) {
        self.title = title
        self.browserViewController = CMUXSidebarExtensionBrowserPresenter.makeViewController(title: title)
        super.init()
    }

    func close() {}

    func focus() {
        guard let window = browserViewController.view.window else { return }
        _ = window.makeFirstResponder(browserViewController.view)
    }

    func unfocus() {}

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
    }
}

struct CMUXSidebarExtensionBrowserPanelView: NSViewControllerRepresentable {
    let panel: CMUXSidebarExtensionBrowserPanel
    let onRequestPanelFocus: () -> Void

    func makeNSViewController(context: Context) -> NSViewController {
        CMUXSidebarExtensionBrowserContainerViewController(
            browserViewController: panel.browserViewController,
            onRequestPanelFocus: onRequestPanelFocus
        )
    }

    func updateNSViewController(_ nsViewController: NSViewController, context: Context) {
        guard let container = nsViewController as? CMUXSidebarExtensionBrowserContainerViewController else {
            return
        }
        container.browserViewController.title = panel.displayTitle
        container.onRequestPanelFocus = onRequestPanelFocus
        container.attachBrowserIfNeeded()
        container.updateLayoutForCurrentBounds()
    }

    static func dismantleNSViewController(
        _ nsViewController: NSViewController,
        coordinator: ()
    ) {
        (nsViewController as? CMUXSidebarExtensionBrowserContainerViewController)?.detachBrowserForTransientReparent()
    }
}

@MainActor
private final class CMUXSidebarExtensionBrowserContainerViewController: NSViewController {
    private final class RootView: NSView {
        var onLayout: (() -> Void)?
        var onMoveToWindow: (() -> Void)?
        var onMouseDown: (() -> Void)?

        override var isFlipped: Bool { true }
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }

        override func mouseDown(with event: NSEvent) {
            onMouseDown?()
            super.mouseDown(with: event)
        }

        override func layout() {
            super.layout()
            onLayout?()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onMoveToWindow?()
        }
    }

    private final class FocusCardView: NSView {
        var onMouseDown: (() -> Void)?

        override var isFlipped: Bool { true }

        override func mouseDown(with event: NSEvent) {
            onMouseDown?()
            super.mouseDown(with: event)
        }
    }

    let browserViewController: NSViewController
    var onRequestPanelFocus: () -> Void

    private let rootView = RootView(frame: .zero)
    private let cardView = FocusCardView(frame: .zero)
    private let contentView = NSView(frame: .zero)
    private let compactLabel = NSTextField(labelWithString: String(
        localized: "sidebar.extensions.browser.compact",
        defaultValue: "Open larger"
    ))
    private var cardWidthConstraint: NSLayoutConstraint?
    private var cardTopConstraint: NSLayoutConstraint?
    private var cardHorizontalSafetyConstraints: [NSLayoutConstraint] = []
    private var cardBottomConstraint: NSLayoutConstraint?
    private var browserConstraints: [NSLayoutConstraint] = []
    private var fontMagnificationObserver: GlobalFontMagnificationChangeObserver?

    init(
        browserViewController: NSViewController,
        onRequestPanelFocus: @escaping () -> Void
    ) {
        self.browserViewController = browserViewController
        self.onRequestPanelFocus = onRequestPanelFocus
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor
        rootView.onLayout = { [weak self] in
            self?.updateLayoutForCurrentBounds()
        }
        rootView.onMouseDown = { [weak self] in
            self?.onRequestPanelFocus()
        }
        rootView.onMoveToWindow = { [weak self] in
            self?.attachBrowserIfNeeded()
            self?.updateLayoutForCurrentBounds()
        }

        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.wantsLayer = true
        cardView.layer?.backgroundColor = Self.cardBackgroundColor.cgColor
        cardView.layer?.cornerRadius = Self.cornerRadius
        cardView.layer?.cornerCurve = .continuous
        cardView.layer?.borderWidth = 1
        cardView.layer?.borderColor = Self.cardBorderColor.cgColor
        cardView.layer?.masksToBounds = true
        cardView.onMouseDown = { [weak self] in
            self?.onRequestPanelFocus()
        }

        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor

        compactLabel.translatesAutoresizingMaskIntoConstraints = false
        compactLabel.alignment = .center
        applyFonts()
        compactLabel.textColor = .secondaryLabelColor
        compactLabel.maximumNumberOfLines = 0
        compactLabel.lineBreakMode = .byWordWrapping
        compactLabel.cell?.wraps = true
        compactLabel.cell?.usesSingleLineMode = false
        compactLabel.isHidden = true
        fontMagnificationObserver = GlobalFontMagnificationChangeObserver { [weak self] in
            self?.applyFonts()
        }

        rootView.addSubview(cardView)
        cardView.addSubview(contentView)
        cardView.addSubview(compactLabel)
        let cardWidthConstraint = cardView.widthAnchor.constraint(equalToConstant: Self.preferredWidth)
        let cardTopConstraint = cardView.topAnchor.constraint(equalTo: rootView.topAnchor, constant: Self.defaultVerticalInset)
        let cardBottomConstraint = cardView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -Self.defaultVerticalInset)
        cardWidthConstraint.priority = .defaultHigh
        cardHorizontalSafetyConstraints = [
            cardView.leadingAnchor.constraint(greaterThanOrEqualTo: rootView.leadingAnchor, constant: Self.defaultHorizontalInset),
            cardView.trailingAnchor.constraint(lessThanOrEqualTo: rootView.trailingAnchor, constant: -Self.defaultHorizontalInset),
        ]
        self.cardWidthConstraint = cardWidthConstraint
        self.cardTopConstraint = cardTopConstraint
        self.cardBottomConstraint = cardBottomConstraint

        NSLayoutConstraint.activate(
            cardHorizontalSafetyConstraints + [
            cardView.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            cardTopConstraint,
            cardBottomConstraint,
            cardWidthConstraint,
            contentView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: cardView.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),
            compactLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 20),
            compactLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -20),
            compactLabel.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
        ])

        view = rootView
        attachBrowserIfNeeded()
    }

    private func applyFonts() {
        compactLabel.font = GlobalFontMagnification.systemFont(ofSize: 13, weight: .medium)
        compactLabel.invalidateIntrinsicContentSize()
    }

    func attachBrowserIfNeeded() {
        guard isViewLoaded else { return }

        if browserViewController.parent !== self {
            if browserViewController.parent != nil {
                browserViewController.removeFromParent()
            }
            browserViewController.view.removeFromSuperview()

            addChild(browserViewController)
            browserViewController.view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(browserViewController.view)
            browserConstraints = [
                browserViewController.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                browserViewController.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                browserViewController.view.topAnchor.constraint(equalTo: contentView.topAnchor),
                browserViewController.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            ]
            NSLayoutConstraint.activate(browserConstraints)
        } else if browserViewController.view.superview !== contentView {
            NSLayoutConstraint.deactivate(browserConstraints)
            browserViewController.view.removeFromSuperview()
            browserViewController.view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(browserViewController.view)
            browserConstraints = [
                browserViewController.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                browserViewController.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                browserViewController.view.topAnchor.constraint(equalTo: contentView.topAnchor),
                browserViewController.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            ]
            NSLayoutConstraint.activate(browserConstraints)
        }

        browserViewController.view.wantsLayer = true
        browserViewController.view.layer?.cornerRadius = Self.cornerRadius
        browserViewController.view.layer?.cornerCurve = .continuous
        browserViewController.view.layer?.masksToBounds = true
    }

    func detachBrowserForTransientReparent() {
        guard browserViewController.parent === self else { return }
        NSLayoutConstraint.deactivate(browserConstraints)
        browserConstraints = []
        browserViewController.view.removeFromSuperview()
        browserViewController.removeFromParent()
    }

    func updateLayoutForCurrentBounds() {
        let visibleBounds = rootView.visibleRect
        let layoutWidth = visibleBounds.width > 0 ? visibleBounds.width : rootView.bounds.width
        let layoutHeight = visibleBounds.height > 0 ? visibleBounds.height : rootView.bounds.height
        let horizontalInset = Self.horizontalInset(for: layoutWidth)
        let verticalInset = Self.verticalInset(for: layoutHeight)
        cardWidthConstraint?.constant = Self.width(for: layoutWidth, horizontalInset: horizontalInset)
        cardTopConstraint?.constant = verticalInset
        cardBottomConstraint?.constant = -verticalInset
        cardHorizontalSafetyConstraints.first?.constant = horizontalInset
        cardHorizontalSafetyConstraints.dropFirst().first?.constant = -horizontalInset

        cardView.layer?.backgroundColor = Self.cardBackgroundColor.cgColor
        cardView.layer?.borderColor = Self.cardBorderColor.cgColor
        cardView.layer?.cornerRadius = Self.cornerRadius
        browserViewController.view.layer?.cornerRadius = Self.cornerRadius
        let isCompact = visibleBounds.width < Self.minimumUsableWidth ||
            visibleBounds.height < Self.minimumUsableHeight
        compactLabel.preferredMaxLayoutWidth = max(0, cardView.bounds.width - 40)
        contentView.isHidden = isCompact
        compactLabel.isHidden = !isCompact
    }

    private static func width(for availableWidth: CGFloat, horizontalInset: CGFloat) -> CGFloat {
        guard availableWidth > 0 else { return preferredWidth }
        let safeWidth = max(0, availableWidth - horizontalInset * 2)
        return min(preferredWidth, safeWidth)
    }

    private static func horizontalInset(for availableWidth: CGFloat) -> CGFloat {
        if availableWidth < 360 { return 8 }
        if availableWidth < 520 { return 12 }
        return defaultHorizontalInset
    }

    private static func verticalInset(for availableHeight: CGFloat) -> CGFloat {
        if availableHeight < 320 { return 8 }
        if availableHeight < 420 { return 12 }
        return defaultVerticalInset
    }

    private static let defaultHorizontalInset: CGFloat = 20
    private static let defaultVerticalInset: CGFloat = 16
    private static let preferredWidth: CGFloat = 1200
    private static let minimumUsableWidth: CGFloat = 600
    private static let minimumUsableHeight: CGFloat = 420
    private static let cornerRadius: CGFloat = 8
    private static var cardBackgroundColor: NSColor {
        NSColor.windowBackgroundColor.withAlphaComponent(0.92)
    }
    private static var cardBorderColor: NSColor {
        NSColor.separatorColor.withAlphaComponent(0.45)
    }
}
